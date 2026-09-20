# macOS port of the Stremio Desktop shell.
#
# Windows uses WebView2 + Win32 + MSVC; macOS uses WKWebView + AppKit + Clang.
# The shared protocol (shell JS bridge, mpv command/observe allow-lists, INI
# settings format, Discord presence payload) is kept byte-compatible with the
# Windows build so the same web UI and add-ons behave identically.

cmake_minimum_required(VERSION 3.16)

enable_language(OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

# libmpv (Homebrew: `brew install mpv`, built with -Dlibmpv=true)
find_package(PkgConfig REQUIRED)
if(APPLE)
  find_program(BREW_EXECUTABLE brew)
  if(BREW_EXECUTABLE)
    execute_process(
      COMMAND "${BREW_EXECUTABLE}" --prefix mpv
      OUTPUT_VARIABLE MPV_PREFIX
      ERROR_QUIET
      OUTPUT_STRIP_TRAILING_WHITESPACE
    )
  endif()
  if(MPV_PREFIX AND EXISTS "${MPV_PREFIX}/lib/pkgconfig")
    set(ENV{PKG_CONFIG_PATH} "${MPV_PREFIX}/lib/pkgconfig:$ENV{PKG_CONFIG_PATH}")
  endif()
endif()
pkg_check_modules(MPV REQUIRED IMPORTED_TARGET mpv)

# nlohmann/json: prefer a system/vcpkg copy, otherwise fetch a pinned release.
find_package(nlohmann_json 3.11.3 QUIET)
if(NOT nlohmann_json_FOUND)
  include(FetchContent)
  FetchContent_Declare(
    nlohmann_json
    GIT_REPOSITORY https://github.com/nlohmann/json.git
    GIT_TAG v3.11.3
    GIT_SHALLOW TRUE
  )
  FetchContent_MakeAvailable(nlohmann_json)
endif()

# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------
set(SOURCES
  main.mm

  Shell.h
  Shell.mm
  MacUtil.h
  MacUtil.mm

  Log.h
  Log.mm
  Strings.h
  Strings.cpp
  IniFile.h
  IniFile.cpp
  Settings.h
  Settings.cpp
  Net.h
  Net.mm
  LocalUiProxy.h
  LocalUiProxy.mm
  Power.h
  Power.mm

  DiscordRpc.h
  DiscordRpc.cpp
  DiscordPresence.h
  DiscordPresence.cpp
  Signature.mm

  MPV.h
  MPV.mm
  MediaKeys.h
  MediaKeys.mm
  VideoView.h
  VideoView.mm

  NodeServer.h
  NodeServer.cpp

  Bridge.h
  Bridge.cpp
  WebShell.h
  WebShell.mm

  Splash.h
  Splash.mm
  Tray.h
  Tray.mm
  AppWindow.h
  AppWindow.mm
  Protocol.h
  Protocol.mm

  Updater.h
  Updater.mm
  Capture.h
  Capture.mm
  SelfTest.h
  SelfTest.mm
)

add_executable(stremio MACOSX_BUNDLE ${SOURCES})

set_target_properties(stremio PROPERTIES
  OUTPUT_NAME "Stremio"
  MACOSX_BUNDLE_BUNDLE_NAME "Stremio"
  MACOSX_BUNDLE_GUI_IDENTIFIER "me.zarg.stremio.desktop"
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
  MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
)

target_compile_definitions(stremio PRIVATE
  APP_VERSION="${PROJECT_VERSION}"
  GL_SILENCE_DEPRECATION # the mpv render API is OpenGL based
  $<$<BOOL:${DEBUG_LOG}>:DEBUG_LOG>
)

target_compile_options(stremio PRIVATE
  -Wall -Wextra -Wpedantic
  # ObjC's `a ?: b` shorthand is idiomatic and used throughout this target.
  $<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-Wno-gnu-conditional-omitted-operand>
  $<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fobjc-arc>
)

target_include_directories(stremio PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

target_link_libraries(stremio PRIVATE
  PkgConfig::MPV
  nlohmann_json::nlohmann_json
  "-framework Cocoa"
  "-framework WebKit"
  "-framework Security"
  "-framework MediaPlayer"
  "-framework QuartzCore"
  "-framework OpenGL"
  "-framework CoreVideo"
  "-framework IOKit"
)

# ---------------------------------------------------------------------------
# Bundled resources
# ---------------------------------------------------------------------------
set(REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../..")
set(RESOURCE_FILES
  "${REPO_ROOT}/images/stremio.png"
)

foreach(res ${RESOURCE_FILES})
  get_filename_component(res_name "${res}" NAME)
  add_custom_command(TARGET stremio POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${res}" "$<TARGET_FILE_DIR:stremio>/../Resources/${res_name}"
    COMMENT "Copying ${res_name}")
endforeach()

# Application icon (.icns) generated from the PNG so no binary blob is committed.
set(ICONSET_DIR "${CMAKE_CURRENT_BINARY_DIR}/AppIcon.iconset")
set(ICNS_FILE "${CMAKE_CURRENT_BINARY_DIR}/AppIcon.icns")
add_custom_command(OUTPUT "${ICNS_FILE}"
  COMMAND ${CMAKE_COMMAND} -E rm -rf "${ICONSET_DIR}"
  COMMAND ${CMAKE_COMMAND} -E make_directory "${ICONSET_DIR}"
  COMMAND sips -z 16 16     "${REPO_ROOT}/images/stremio2.png" --out "${ICONSET_DIR}/icon_16x16.png"
  COMMAND sips -z 32 32     "${REPO_ROOT}/images/stremio2.png" --out "${ICONSET_DIR}/icon_16x16@2x.png"
  COMMAND sips -z 32 32     "${REPO_ROOT}/images/stremio2.png" --out "${ICONSET_DIR}/icon_32x32.png"
  COMMAND sips -z 64 64     "${REPO_ROOT}/images/stremio2.png" --out "${ICONSET_DIR}/icon_32x32@2x.png"
  COMMAND sips -z 128 128   "${REPO_ROOT}/images/stremio2.png" --out "${ICONSET_DIR}/icon_128x128.png"
  COMMAND sips -z 256 256   "${REPO_ROOT}/images/stremio2.png" --out "${ICONSET_DIR}/icon_128x128@2x.png"
  COMMAND sips -z 256 256   "${REPO_ROOT}/images/stremio2.png" --out "${ICONSET_DIR}/icon_256x256.png"
  COMMAND sips -z 512 512   "${REPO_ROOT}/images/stremio2.png" --out "${ICONSET_DIR}/icon_256x256@2x.png"
  COMMAND sips -z 512 512   "${REPO_ROOT}/images/stremio2.png" --out "${ICONSET_DIR}/icon_512x512.png"
  COMMAND sips -z 1024 1024 "${REPO_ROOT}/images/stremio2.png" --out "${ICONSET_DIR}/icon_512x512@2x.png"
  COMMAND iconutil -c icns "${ICONSET_DIR}" -o "${ICNS_FILE}"
  COMMENT "Generating AppIcon.icns"
  VERBATIM)

add_custom_target(stremio_icns DEPENDS "${ICNS_FILE}")
add_dependencies(stremio stremio_icns)
add_custom_command(TARGET stremio POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different "${ICNS_FILE}" "$<TARGET_FILE_DIR:stremio>/../Resources/AppIcon.icns"
  COMMENT "Copying AppIcon.icns")

# Self-test harness page (web UI protocol simulation).
add_custom_command(TARGET stremio POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          "${CMAKE_CURRENT_SOURCE_DIR}/Resources/selftest.html"
          "$<TARGET_FILE_DIR:stremio>/../Resources/selftest.html"
  COMMENT "Copying selftest.html")

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
if(APPLE)
  add_subdirectory(tests)
endif()
