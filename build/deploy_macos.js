#!/usr/bin/env node

/****************************************************************************
 * deploy_macos.js
 *
 * Builds a distributable Stremio.app for macOS into dist/mac.
 *
 *   node deploy_macos.js                 build (Release) + stage resources
 *   node deploy_macos.js --debug         build with DEBUG_LOG/devtools
 *   node deploy_macos.js --zip           also produce dist/mac/Stremio-<ver>.zip
 *   node deploy_macos.js --dmg           also produce a drag-to-install .dmg
 *   node deploy_macos.js --pkg           also produce a .pkg installer
 *   node deploy_macos.js --install       copy the app into /Applications
 *
 * Requirements:
 *   - Xcode command line tools, cmake, pkg-config
 *   - brew install mpv (libmpv with the render API)
 *   - node (the streaming server runtime; bundled when available)
 *
 * The script mirrors build/deploy_windows.js: it builds the app, downloads
 * server.js into the bundle resources and stages the optional runtime pieces
 * (node, ffmpeg, ffprobe) next to the executable, exactly like the official
 * macOS shell layout (Contents/MacOS/node, Contents/MacOS/server.js).
 ****************************************************************************/

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const SOURCE_DIR = path.resolve(__dirname, '..');
const BUILD_DIR = path.join(SOURCE_DIR, 'build-macos');
const DIST_DIR = path.join(SOURCE_DIR, 'dist', 'mac');
const APP_NAME = 'Stremio.app';
const SERVER_JS_URL =
  'https://dl.strem.io/server/v4.20.15/desktop/server.js';

const args = process.argv.slice(2);
const debugBuild = args.includes('--debug');
const makeZip = args.includes('--zip');
const makeDmg = args.includes('--dmg');
const makePkg = args.includes('--pkg');
const installApp = args.includes('--install');

function run(command, options = {}) {
  console.log(`$ ${command}`);
  execSync(command, { stdio: 'inherit', ...options });
}

function appVersion() {
  const cmake = fs.readFileSync(path.join(SOURCE_DIR, 'CMakeLists.txt'), 'utf8');
  const match = cmake.match(/project\(stremio VERSION "([^"]+)"/);
  return match ? match[1] : '0.0.0';
}

async function download(url, destination) {
  console.log(`Downloading ${url}`);
  const response = await fetch(url);
  if (!response.ok) throw new Error(`download failed: ${response.status}`);
  const buffer = Buffer.from(await response.arrayBuffer());
  fs.writeFileSync(destination, buffer);
  console.log(`  -> ${destination} (${buffer.length} bytes)`);
}

(async function main() {
  try {
    const version = appVersion();
    console.log(`\n=== Building Stremio ${version} for macOS ===`);

    const buildType = debugBuild ? 'Debug' : 'Release';
    run(
      `cmake -S "${SOURCE_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=${buildType}` +
        (debugBuild ? ' -DDEBUG_LOG=ON' : ' -DDEBUG_LOG=OFF'),
      { cwd: SOURCE_DIR }
    );
    run(`cmake --build "${BUILD_DIR}" -j8`, { cwd: SOURCE_DIR });

    const builtApp = path.join(BUILD_DIR, 'src', 'macos', APP_NAME);
    if (!fs.existsSync(builtApp)) {
      throw new Error(`build output not found: ${builtApp}`);
    }

    // Stage into dist/mac.
    fs.rmSync(DIST_DIR, { recursive: true, force: true });
    fs.mkdirSync(DIST_DIR, { recursive: true });
    run(`ditto "${builtApp}" "${path.join(DIST_DIR, APP_NAME)}"`);

    const appRoot = path.join(DIST_DIR, APP_NAME);
    const macosDir = path.join(appRoot, 'Contents', 'MacOS');
    const resourcesDir = path.join(appRoot, 'Contents', 'Resources');

    // server.js: portable_config/server.js takes precedence at runtime, but a
    // copy in Resources makes a fresh install work without a first-run update.
    await download(SERVER_JS_URL, path.join(resourcesDir, 'server.js'));

    // Bundle the node runtime (same layout as the official shell: node next to
    // the executable). Homebrew's node is not relocatable, so prefer an
    // explicit runtime or download the official self-contained build.
    await bundleNode(macosDir);

    // ffmpeg/ffprobe: the streaming server uses them for transcoding. A
    // Homebrew binary needs its dylibs, so use dylibbundler when available.
    for (const tool of ['ffmpeg', 'ffprobe']) {
      bundleTool(tool, macosDir, appRoot);
    }

    // Default settings template.
    const settingsTemplate = path.join(SOURCE_DIR, 'utils', 'stremio', 'stremio-settings.ini');
    if (fs.existsSync(settingsTemplate)) {
      const portableConfig = path.join(resourcesDir, 'portable_config');
      fs.mkdirSync(portableConfig, { recursive: true });
      fs.copyFileSync(settingsTemplate, path.join(portableConfig, 'stremio-settings.ini'));
    }

    // Ad-hoc sign so Gatekeeper can launch the bundle locally.
    run(`codesign --force --deep --sign - "${appRoot}" || true`);

    if (makeZip) {
      const zipPath = path.join(DIST_DIR, `Stremio-${version}.zip`);
      run(`ditto -c -k --keepParent "${appRoot}" "${zipPath}"`);
      console.log(`\nArchive: ${zipPath}`);
    }

    if (makeDmg) {
      buildDmg(appRoot, version);
    }

    if (makePkg) {
      buildPkg(appRoot, version);
    }

    if (installApp) {
      installToApplications(appRoot);
    }

    console.log(`\nDone. App bundle: ${appRoot}`);
    console.log('Run it with: open "' + appRoot + '"');
  } catch (error) {
    console.error(`\ndeploy_macos failed: ${error.message}`);
    process.exit(1);
  }
})();

const NODE_VERSION = 'v22.14.0';

async function bundleNode(macosDir) {
  const target = path.join(macosDir, 'node');

  // 1) Explicit runtime (stremio-runtime or a self-contained node).
  const explicit = process.env.STREMIO_NODE_PATH || which('stremio-runtime');
  if (explicit && fs.existsSync(explicit)) {
    fs.copyFileSync(explicit, target);
    fs.chmodSync(target, 0o755);
    if (isRunnable(target)) {
      console.log(`Bundled runtime: ${explicit}`);
      return;
    }
    fs.rmSync(target, { force: true });
    console.log(`Ignoring non-runnable runtime: ${explicit}`);
  }

  // 2) Official node build (self-contained, links only against system libs).
  const arch = process.arch === 'arm64' ? 'arm64' : 'x64';
  const tarball = `node-${NODE_VERSION}-darwin-${arch}.tar.gz`;
  const url = `https://nodejs.org/dist/${NODE_VERSION}/${tarball}`;
  const tempDir = path.join(DIST_DIR, 'node-download');

  try {
    fs.rmSync(tempDir, { recursive: true, force: true });
    fs.mkdirSync(tempDir, { recursive: true });
    await download(url, path.join(tempDir, tarball));
    run(`tar -xzf "${path.join(tempDir, tarball)}" -C "${tempDir}"`);
    const extracted = path.join(tempDir, `node-${NODE_VERSION}-darwin-${arch}`, 'bin', 'node');
    fs.copyFileSync(extracted, target);
    fs.chmodSync(target, 0o755);

    const license = path.join(tempDir, `node-${NODE_VERSION}-darwin-${arch}`, 'LICENSE');
    if (fs.existsSync(license)) {
      fs.copyFileSync(license, path.join(macosDir, 'node-LICENSE'));
    }

    if (!isRunnable(target)) {
      fs.rmSync(target, { force: true });
      throw new Error('downloaded node failed to start');
    }
    console.log(`Bundled node ${NODE_VERSION} (${arch})`);
  } catch (error) {
    console.log(`Could not bundle node (${error.message}); the app will use node from PATH.`);
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

// Copies a Homebrew tool into the bundle and makes it self-contained with
// dylibbundler (no-op when the tool is already relocatable).
function bundleTool(tool, macosDir, appRoot) {
  const source = process.env[`STREMIO_${tool.toUpperCase()}_PATH`] || which(tool);
  if (!source || !fs.existsSync(source)) {
    console.log(`No ${tool} found; the streaming server will use it from PATH.`);
    return;
  }

  const target = path.join(macosDir, tool);
  fs.rmSync(target, { force: true });
  fs.copyFileSync(fs.realpathSync(source), target);
  fs.chmodSync(target, 0o755);

  // A Homebrew tool links against absolute /opt/homebrew paths; make it
  // self-contained so the bundle works on machines without Homebrew.
  const frameworksDir = path.join(appRoot, 'Contents', 'Frameworks');
  if (which('dylibbundler')) {
    try {
      fs.mkdirSync(frameworksDir, { recursive: true });
      run(
        `dylibbundler -of -b -x "${target}" -d "${frameworksDir}" ` +
          `-p "@executable_path/../Frameworks" >/dev/null`
      );
      console.log(`Bundled ${tool} with its dylibs: ${source}`);
    } catch (error) {
      console.log(`dylibbundler failed for ${tool}: ${error.message}`);
    }
  } else {
    console.log(
      `Bundled ${tool} as-is (install dylibbundler to make it self-contained): ${source}`
    );
  }

  if (!isRunnable(target)) {
    fs.rmSync(target, { force: true });
    console.log(`Removed non-runnable ${tool}: ${source}`);
  }
}

function isRunnable(binary) {
  // node/stremio-runtime use --version, ffmpeg/ffprobe use -version.
  for (const flag of ['--version', '-version']) {
    try {
      const output = execSync(`"${binary}" ${flag}`, {
        encoding: 'utf8',
        timeout: 10000,
        stdio: ['ignore', 'pipe', 'ignore'],
      });
      if (output.trim().length > 0) return true;
    } catch {
      // try the next flag
    }
  }
  return false;
}

// Drag-to-install disk image: the app plus an /Applications symlink.
function buildDmg(appRoot, version) {
  const dmgPath = path.join(DIST_DIR, `Stremio-${version}.dmg`);
  const stagingDir = path.join(DIST_DIR, 'dmg-staging');

  fs.rmSync(stagingDir, { recursive: true, force: true });
  fs.mkdirSync(stagingDir, { recursive: true });
  run(`ditto "${appRoot}" "${path.join(stagingDir, APP_NAME)}"`);
  fs.symlinkSync('/Applications', path.join(stagingDir, 'Applications'));

  fs.rmSync(dmgPath, { force: true });
  run(
    `hdiutil create -volname "Stremio ${version}" -srcfolder "${stagingDir}" ` +
      `-fs HFS+ -format UDZO -imagekey zlib-level=9 "${dmgPath}"`
  );
  fs.rmSync(stagingDir, { recursive: true, force: true });

  console.log(`\nDisk image: ${dmgPath}`);
  console.log('Open it and drag Stremio onto Applications.');
}

// Standard macOS installer package (installs into /Applications).
function buildPkg(appRoot, version) {
  const componentPkg = path.join(DIST_DIR, `Stremio-${version}-component.pkg`);
  const finalPkg = path.join(DIST_DIR, `Stremio-${version}.pkg`);
  const scriptsDir = path.join(DIST_DIR, 'pkg-scripts');
  const resourcesDir = path.join(DIST_DIR, 'pkg-resources');

  fs.rmSync(scriptsDir, { recursive: true, force: true });
  fs.mkdirSync(scriptsDir, { recursive: true });
  fs.writeFileSync(
    path.join(scriptsDir, 'postinstall'),
    [
      '#!/bin/bash',
      '# Register the bundle with LaunchServices so stremio:// and magnet: work',
      '# immediately, without waiting for the first launch.',
      '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \\',
      '  -f "/Applications/Stremio.app" >/dev/null 2>&1 || true',
      'exit 0',
      '',
    ].join('\n')
  );
  fs.chmodSync(path.join(scriptsDir, 'postinstall'), 0o755);

  fs.mkdirSync(resourcesDir, { recursive: true });
  fs.writeFileSync(
    path.join(resourcesDir, 'welcome.html'),
    `<html><body style="font-family: -apple-system, sans-serif; font-size: 13px;">` +
      `<p>This installs <b>Stremio ${version}</b> into your Applications folder.</p>` +
      `<p>Stremio is community software, not affiliated with Stremio.</p></body></html>`
  );
  fs.writeFileSync(
    path.join(resourcesDir, 'conclusion.html'),
    `<html><body style="font-family: -apple-system, sans-serif; font-size: 13px;">` +
      `<p>Stremio was installed. Open it from Applications or Launchpad.</p></body></html>`
  );

  run(
    `pkgbuild --component "${appRoot}" --install-location /Applications ` +
      `--identifier me.zarg.stremio.desktop --version ${version} ` +
      `--scripts "${scriptsDir}" "${componentPkg}"`
  );
  const distributionPath = path.join(resourcesDir, 'distribution.xml');
  fs.writeFileSync(
    distributionPath,
    `<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
  <title>Stremio ${version}</title>
  <welcome file="welcome.html"/>
  <conclusion file="conclusion.html"/>
  <options customize="never" require-scripts="true" hostArchitectures="arm64,x86_64"/>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <choices-outline><line choice="default"/></choices-outline>
  <choice id="default" title="Stremio">
    <pkg-ref id="me.zarg.stremio.desktop"/>
  </choice>
  <pkg-ref id="me.zarg.stremio.desktop" version="${version}" onConclusion="none">${path.basename(componentPkg)}</pkg-ref>
</installer-gui-script>
`
  );

  run(
    `productbuild --distribution "${distributionPath}" --resources "${resourcesDir}" ` +
      `--package-path "${DIST_DIR}" "${finalPkg}"`
  );

  fs.rmSync(componentPkg, { force: true });
  fs.rmSync(scriptsDir, { recursive: true, force: true });
  fs.rmSync(resourcesDir, { recursive: true, force: true });

  console.log(`\nInstaller package: ${finalPkg}`);
  console.log('Double-click it (or: sudo installer -pkg "' + finalPkg + '" -target /).');
}

function installToApplications(appRoot) {
  const target = path.join('/Applications', APP_NAME);
  try {
    fs.rmSync(target, { recursive: true, force: true });
    run(`ditto "${appRoot}" "${target}"`);
    run(
      `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${target}"`
    );
    console.log(`\nInstalled: ${target}`);
    console.log('Launch it from Launchpad, Spotlight or: open -a Stremio');
  } catch (error) {
    console.log(`\nCould not install into /Applications (${error.message}); use the .dmg or .pkg.`);
  }
}

function which(binary) {
  try {
    return execSync(`command -v ${binary}`, { encoding: 'utf8' }).trim();
  } catch {
    return null;
  }
}
