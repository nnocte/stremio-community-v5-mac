// Unit tests for the platform-neutral macOS modules (CTest: unit_tests).
//
// Real-world vectors are used wherever possible: the update manifest signature
// is verified against the repository's signed version files, and the INI tests
// exercise the exact file layout of the Windows build.

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

#include "IniFile.h"
#include "Settings.h"
#include "Shell.h"
#include "Strings.h"

#include "nlohmann/json.hpp"

#ifndef TEST_REPO_DIR
#define TEST_REPO_DIR "."
#endif

namespace {

int g_failures = 0;
int g_checks = 0;

#define CHECK(condition)                                                       \
  do {                                                                         \
    g_checks++;                                                                \
    if (!(condition)) {                                                        \
      g_failures++;                                                            \
      std::cout << "FAIL " << __func__ << ":" << __LINE__ << "  " << #condition \
                << std::endl;                                                  \
    }                                                                          \
  } while (0)

std::filesystem::path MakeTempDir(const std::string &name) {
  std::filesystem::path dir = std::filesystem::temp_directory_path() / name;
  std::filesystem::remove_all(dir);
  std::filesystem::create_directories(dir);
  return dir;
}

void test_ini_roundtrip() {
  auto dir = MakeTempDir("stremio-tests-ini");
  std::filesystem::path path = dir / "test.ini";

  IniFile ini(path.string());
  CHECK(ini.Load() == false);
  ini.Set("General", "CloseOnExit", "1");
  ini.Set("General", "UseDarkTheme", "0");
  ini.Set("MPV", "InitialVolume", "42");
  CHECK(ini.Save());

  IniFile reloaded(path.string());
  CHECK(reloaded.Load() == true);
  CHECK(reloaded.Get("General", "CloseOnExit") == "1");
  CHECK(reloaded.Get("General", "UseDarkTheme") == "0");
  CHECK(reloaded.GetInt("MPV", "InitialVolume", 0) == 42);
  CHECK(reloaded.GetInt("MPV", "Missing", 7) == 7);
  CHECK(reloaded.Get("general", "closeonexit") == "1"); // case-insensitive
  CHECK(reloaded.GetInt("MPV", "InitialVolume", 0) == 42);
}

void test_ini_preserves_unknown_content() {
  auto dir = MakeTempDir("stremio-tests-ini-preserve");
  std::filesystem::path path = dir / "test.ini";

  {
    std::ofstream out(path);
    out << "; my comment\n";
    out << "[General]\n";
    out << "CloseOnExit=0\n";
    out << "CustomKey=custom\n";
    out << "\n";
    out << "[Other]\n";
    out << "Foo=Bar\n";
  }

  IniFile ini(path.string());
  CHECK(ini.Load());
  ini.Set("General", "CloseOnExit", "1");
  ini.Set("General", "NewKey", "new");
  CHECK(ini.Save());

  std::string content;
  CHECK(ReadFileUtf8(path.string(), content));
  CHECK(content.find("; my comment") != std::string::npos);
  CHECK(content.find("CustomKey=custom") != std::string::npos);
  CHECK(content.find("Foo=Bar") != std::string::npos);
  CHECK(content.find("CloseOnExit=1") != std::string::npos);
  CHECK(content.find("NewKey=new") != std::string::npos);

  IniFile reloaded(path.string());
  CHECK(reloaded.Load());
  CHECK(reloaded.Get("General", "CustomKey") == "custom");
  CHECK(reloaded.Get("Other", "Foo") == "Bar");
  CHECK(reloaded.Get("General", "NewKey") == "new");
}

void test_strings() {
  CHECK(ToLowerStr("AbC") == "abc");
  CHECK(decodeURIComponent("a%20b") == "a b");
  CHECK(decodeURIComponent("%C3%A9") == "\xc3\xa9");
  CHECK(decodeURIComponent("100%25") == "100%");
  CHECK(decodeURIComponent("plain") == "plain");

  CHECK(isSubtitle("/tmp/Movie.SRT"));
  CHECK(isSubtitle("subs/movie.ass"));
  CHECK(!isSubtitle("movie.mkv"));

  CHECK(Base64Encode("hello") == "aGVsbG8=");
  CHECK(Base64Encode("") == "");
  CHECK(Base64Encode("ab") == "YWI=");

  std::string css = MakeInjectCssScript("webmods_test_css", "body { color: red; }");
  CHECK(css.find("webmods-css-webmods_test_css") != std::string::npos);
  CHECK(css.find(Base64Encode("body { color: red; }")) != std::string::npos);

  std::string js = MakeInjectJsScript("webmods_test_js", "window.__x = 1;");
  CHECK(js.find(Base64Encode("window.__x = 1;")) != std::string::npos);
}

void test_sha256() {
  auto dir = MakeTempDir("stremio-tests-sha");
  std::filesystem::path path = dir / "abc.txt";
  CHECK(WriteFileUtf8(path.string(), "abc"));
  CHECK(Sha256File(path) ==
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}

void test_update_signature() {
  std::string detailsPath = std::string(TEST_REPO_DIR) + "/version/version-details.json";
  std::string versionPath = std::string(TEST_REPO_DIR) + "/version/version.json";

  std::string details;
  std::string versionContent;
  if (!ReadFileUtf8(detailsPath, details) || !ReadFileUtf8(versionPath, versionContent)) {
    std::cout << "SKIP test_update_signature (repo files not found)" << std::endl;
    return;
  }

  nlohmann::json versionJson = nlohmann::json::parse(versionContent);
  std::string signature = versionJson["signature"].get<std::string>();

  CHECK(VerifyUpdateSignature(details, signature));

  std::string tampered = details;
  tampered[0] = tampered[0] == '{' ? '[' : '{';
  CHECK(!VerifyUpdateSignature(tampered, signature));

  CHECK(!VerifyUpdateSignature(details, "AAAA"));
}

void test_settings_allowlist_merge() {
  auto dir = MakeTempDir("stremio-tests-settings");
  g_configDir = dir.string();

  std::string iniPath = GetSettingsIniPath();
  CHECK(WriteFileUtf8(iniPath, "[General]\nUseDarkTheme=0\n[Security]\n"
                               "MpvCommandAllowlist=mycmd,loadfile\n"
                               "MpvSetPropAllowlist=myprop\n"));

  LoadSettings();

  CHECK(g_mpvCommandAllowlist.count("loadfile") == 1); // default
  CHECK(g_mpvCommandAllowlist.count("mycmd") == 1);    // user extra
  CHECK(g_mpvSetPropAllowlist.count("myprop") == 1);   // user extra
  CHECK(g_mpvSetPropAllowlist.count("volume") == 1);   // default
  CHECK(g_useDarkTheme == false);
  CHECK(g_pauseOnMinimize == true);
  CHECK(g_currentVolume == 50);
  CHECK(g_initialVO == "libmpv");

  // Defaults missing from the user list must be written back (Windows parity).
  std::string rewritten;
  CHECK(ReadFileUtf8(iniPath, rewritten));
  CHECK(rewritten.find("script-message-to") != std::string::npos);
  CHECK(rewritten.find("mycmd") != std::string::npos);
}

void test_settings_save_roundtrip() {
  auto dir = MakeTempDir("stremio-tests-settings-save");
  g_configDir = dir.string();

  g_closeOnExit = true;
  g_useDarkTheme = false;
  g_pauseOnMinimize = false;
  g_pauseOnLostFocus = true;
  g_allowZoom = true;
  g_isRpcOn = false;
  g_currentVolume = 77;
  SaveSettings();

  g_closeOnExit = false;
  g_useDarkTheme = true;
  g_pauseOnMinimize = true;
  g_pauseOnLostFocus = false;
  g_allowZoom = false;
  g_isRpcOn = true;
  g_currentVolume = 10;

  LoadSettings();
  CHECK(g_closeOnExit == true);
  CHECK(g_useDarkTheme == false);
  CHECK(g_pauseOnMinimize == false);
  CHECK(g_pauseOnLostFocus == true);
  CHECK(g_allowZoom == true);
  CHECK(g_isRpcOn == false);
  CHECK(g_currentVolume == 77);
}

void test_window_placement_roundtrip() {
  auto dir = MakeTempDir("stremio-tests-window");
  g_configDir = dir.string();

  WindowPlacement saved;
  saved.left = 10;
  saved.top = 20;
  saved.right = 1210;
  saved.bottom = 920;
  saved.showCmd = 3;
  saved.valid = true;
  SaveWindowPlacement(saved);

  WindowPlacement loaded;
  CHECK(LoadWindowPlacement(loaded));
  CHECK(loaded.left == 10 && loaded.top == 20);
  CHECK(loaded.right == 1210 && loaded.bottom == 920);
  CHECK(loaded.showCmd == 3);
}

} // namespace

int main() {
  test_ini_roundtrip();
  test_ini_preserves_unknown_content();
  test_strings();
  test_sha256();
  test_update_signature();
  test_settings_allowlist_merge();
  test_settings_save_roundtrip();
  test_window_placement_roundtrip();

  std::cout << (g_failures == 0 ? "OK" : "FAILED") << ": " << (g_checks - g_failures) << "/"
            << g_checks << " checks passed" << std::endl;
  return g_failures == 0 ? 0 : 1;
}
