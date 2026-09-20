#ifndef STRINGS_H
#define STRINGS_H

#include <string>
#include <vector>

// UTF-8 string helpers ported from the Windows build (src/utils/helpers.cpp).
std::string ToLowerStr(std::string s);
std::string decodeURIComponent(const std::string &encoded);
bool FileExists(const std::string &path);
bool DirectoryExists(const std::string &dirPath);
bool isSubtitle(const std::string &filePath);
bool ReadFileUtf8(const std::string &path, std::string &out);
std::string FilePathToFileUrl(const std::string &path);
bool WriteFileUtf8(const std::string &path, const std::string &content);

// Web mods injectors (identical JS to the Windows build).
std::string Base64Encode(const std::string &in);
std::string MakeInjectCssScript(const std::string &idSafe, const std::string &cssUtf8);
std::string MakeInjectJsScript(const std::string &idSafe, const std::string &jsUtf8);

#endif // STRINGS_H
