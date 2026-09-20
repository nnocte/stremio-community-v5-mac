# Unit tests + end-to-end self test for the macOS port.
#
# The unit tests link the platform-neutral modules directly; the integration
# test drives the real app binary in --self-test mode.

add_executable(stremio_tests
  unit_tests.cpp
  ../Strings.cpp
  ../IniFile.cpp
  ../Settings.cpp
  ../Shell.mm
  ../MacUtil.mm
  ../Log.mm
  ../Signature.mm
)

set_target_properties(stremio_tests PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
)

target_include_directories(stremio_tests PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/.."
  "${CMAKE_BINARY_DIR}/_deps/nlohmann_json-src/include"
)

target_compile_definitions(stremio_tests PRIVATE
  APP_VERSION="${PROJECT_VERSION}"
  TEST_REPO_DIR="${CMAKE_SOURCE_DIR}"
)
target_compile_options(stremio_tests PRIVATE
  -Wall -Wextra
  $<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fobjc-arc>
)

target_link_libraries(stremio_tests PRIVATE
  PkgConfig::MPV
  nlohmann_json::nlohmann_json
  "-framework Foundation"
  "-framework AppKit"
  "-framework Security"
)

add_test(NAME unit_tests COMMAND stremio_tests)

# End-to-end: real app, real WKWebView, real mpv playback, real JS bridge.
add_test(NAME selftest_protocol
  COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/run_selftest.sh"
          "$<TARGET_FILE:stremio>"
          "${CMAKE_BINARY_DIR}"
)
set_tests_properties(selftest_protocol PROPERTIES TIMEOUT 180)

# Live verification against the real web UI (startup, playback, forwarding).
add_test(NAME live_webui
  COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/live_webui_test.sh"
          "$<TARGET_FILE:stremio>"
          "${CMAKE_BINARY_DIR}/live-test-work"
)
set_tests_properties(live_webui PROPERTIES TIMEOUT 420)

# Network reachability of the web UI endpoints.
add_test(NAME endpoints_reachable
  COMMAND "$<TARGET_FILE:stremio>" --check-endpoints
)
set_tests_properties(endpoints_reachable PROPERTIES TIMEOUT 60)
