#!/usr/bin/env node

/****************************************************************************
 * deploy_macos.js
 *
 * Builds a distributable Stremio.app for macOS into dist/mac.
 *
 *   node deploy_macos.js                 build (Release) + stage resources
 *   node deploy_macos.js --debug         build with DEBUG_LOG/devtools
 *   node deploy_macos.js --zip           also produce dist/mac/Stremio-<ver>.zip
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

    // Bundle the node runtime and ffmpeg when present (same layout as the
    // official shell: node/ffmpeg/ffprobe next to the executable).
    const nodePath = process.env.STREMIO_NODE_PATH || which('node');
    if (nodePath && fs.existsSync(nodePath)) {
      fs.copyFileSync(nodePath, path.join(macosDir, 'node'));
      fs.chmodSync(path.join(macosDir, 'node'), 0o755);
      console.log(`Bundled node: ${nodePath}`);
    } else {
      console.log('No node runtime bundled; the app will look it up in PATH.');
    }

    const ffmpegPath = process.env.STREMIO_FFMPEG_PATH || which('ffmpeg');
    if (ffmpegPath && fs.existsSync(ffmpegPath)) {
      fs.copyFileSync(ffmpegPath, path.join(macosDir, 'ffmpeg'));
      fs.chmodSync(path.join(macosDir, 'ffmpeg'), 0o755);
      console.log(`Bundled ffmpeg: ${ffmpegPath}`);
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

    console.log(`\nDone. App bundle: ${appRoot}`);
    console.log('Run it with: open "' + appRoot + '"');
  } catch (error) {
    console.error(`\ndeploy_macos failed: ${error.message}`);
    process.exit(1);
  }
})();

function which(binary) {
  try {
    return execSync(`command -v ${binary}`, { encoding: 'utf8' }).trim();
  } catch {
    return null;
  }
}
