#include "Strings.h"

#include <CommonCrypto/CommonDigest.h>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <sstream>

#include "Shell.h"

std::string Sha256File(const std::filesystem::path &filepath) {
  std::ifstream file(filepath, std::ios::binary);
  if (!file) return "";

  CC_SHA256_CTX context;
  CC_SHA256_Init(&context);

  char buffer[4096];
  while (file) {
    file.read(buffer, sizeof(buffer));
    std::streamsize got = file.gcount();
    if (got > 0) {
      CC_SHA256_Update(&context, buffer, (CC_LONG)got);
    }
  }

  unsigned char hash[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(hash, &context);

  std::ostringstream oss;
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) {
    oss << std::hex << std::setw(2) << std::setfill('0') << (int)hash[i];
  }
  return oss.str();
}

std::string ToLowerStr(std::string s) {
  std::transform(s.begin(), s.end(), s.begin(),
                 [](unsigned char c) { return (char)std::tolower(c); });
  return s;
}

bool FileExists(const std::string &path) {
  std::error_code ec;
  return std::filesystem::is_regular_file(path, ec);
}

bool DirectoryExists(const std::string &dirPath) {
  std::error_code ec;
  return std::filesystem::is_directory(dirPath, ec);
}

// Ported verbatim from src/utils/helpers.cpp (same percent-decoding rules).
std::string decodeURIComponent(const std::string &encoded) {
  std::string result;
  result.reserve(encoded.size());

  for (size_t i = 0; i < encoded.size(); ++i) {
    char c = encoded[i];
    if (c == '%' && i + 2 < encoded.size() &&
        std::isxdigit(static_cast<unsigned char>(encoded[i + 1])) &&
        std::isxdigit(static_cast<unsigned char>(encoded[i + 2]))) {
      std::string hex = encoded.substr(i + 1, 2);
      result.push_back(static_cast<char>(std::strtol(hex.c_str(), nullptr, 16)));
      i += 2;
    } else {
      result.push_back(c);
    }
  }
  return result;
}

bool isSubtitle(const std::string &filePath) {
  std::string lower = ToLowerStr(filePath);
  return std::any_of(g_subtitleExtensions.begin(), g_subtitleExtensions.end(),
                     [&](const std::string &ext) {
                       return lower.size() >= ext.size() &&
                              lower.compare(lower.size() - ext.size(), ext.size(), ext) == 0;
                     });
}

// The web UI's decodeStream() deserializes the URL into an absolute Url, so
// local files must be handed over as file:// URLs (the official shell passes
// paths only because the official UI converts them itself).
std::string FilePathToFileUrl(const std::string &path) {
  static const char *hex = "0123456789ABCDEF";
  std::string encoded;
  encoded.reserve(path.size() + 8);
  for (unsigned char c : path) {
    bool unreserved = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                      (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' ||
                      c == '~' || c == '/';
    if (unreserved) {
      encoded.push_back((char)c);
    } else {
      encoded.push_back('%');
      encoded.push_back(hex[c >> 4]);
      encoded.push_back(hex[c & 0x0F]);
    }
  }
  if (!encoded.empty() && encoded[0] != '/') encoded.insert(encoded.begin(), '/');
  return "file://" + encoded;
}

bool ReadFileUtf8(const std::string &path, std::string &out) {
  std::ifstream f(path, std::ios::binary);
  if (!f) return false;
  f.seekg(0, std::ios::end);
  std::streamsize size = f.tellg();
  f.seekg(0, std::ios::beg);
  out.resize(static_cast<size_t>(size));
  if (size > 0) f.read(&out[0], size);
  return true;
}

bool WriteFileUtf8(const std::string &path, const std::string &content) {
  std::ofstream f(path, std::ios::binary | std::ios::trunc);
  if (!f) return false;
  f.write(content.data(), (std::streamsize)content.size());
  return f.good();
}

std::string Base64Encode(const std::string &in) {
  static const char *T = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  out.reserve(((in.size() + 2) / 3) * 4);
  int val = 0, valb = -6;
  for (uint8_t c : in) {
    val = (val << 8) + c;
    valb += 8;
    while (valb >= 0) {
      out.push_back(T[(val >> valb) & 0x3F]);
      valb -= 6;
    }
  }
  if (valb > -6) out.push_back(T[((val << 8) >> (valb + 8)) & 0x3F]);
  while (out.size() % 4) out.push_back('=');
  return out;
}

// Same injected JS as the Windows build (src/utils/helpers.cpp) so webmods CSS
// and JS files behave identically.
std::string MakeInjectCssScript(const std::string &idSafe, const std::string &cssUtf8) {
  const std::string b64 = Base64Encode(cssUtf8);
  std::ostringstream ss;

  ss << "(function(){try{"
        "if(window.top!==window)return;"
        "var id='webmods-css-"
     << idSafe
     << "';"
        "function inject(){"
        "try{"
        "var root=document.head||document.documentElement||document.body;"
        "if(!root){"
        "document.addEventListener('DOMContentLoaded',inject,{once:true});"
        "document.addEventListener('readystatechange',function(){"
        "if(document.readyState==='interactive'||document.readyState==='complete')inject();"
        "},{once:true});"
        "setTimeout(inject,25);"
        "return;"
        "}"
        "if(document.getElementById(id))return;"
        "var bin=atob('"
     << b64
     << "');"
        "var bytes=new Uint8Array(bin.length);"
        "for(var i=0;i<bin.length;i++)bytes[i]=bin.charCodeAt(i);"
        "var css='';"
        "try{css=new TextDecoder('utf-8').decode(bytes);}catch(e){css=decodeURIComponent(escape(bin));}"
        "var s=document.createElement('style');"
        "s.id=id;"
        "s.textContent=css;"
        "root.appendChild(s);"
        "}catch(e){console.error('webmods css inject tick failed:',e);setTimeout(inject,50);}"
        "}"
        "inject();"
        "}catch(e){console.error('webmods css inject failed:',e);}})();";

  return ss.str();
}

std::string MakeInjectJsScript(const std::string &, const std::string &jsUtf8) {
  const std::string b64 = Base64Encode(jsUtf8);
  std::ostringstream ss;

  ss << "(function(){try{"
        "if(window.top!==window)return;"
        "function run(){"
        "try{"
        "var bin=atob('"
     << b64
     << "');"
        "var bytes=new Uint8Array(bin.length);"
        "for(var i=0;i<bin.length;i++)bytes[i]=bin.charCodeAt(i);"
        "var js='';"
        "try{js=new TextDecoder('utf-8').decode(bytes);}catch(e){js=decodeURIComponent(escape(bin));}"
        "(0,eval)(js);"
        "}catch(e){console.error('webmods js exec tick failed:',e);setTimeout(run,25);}"
        "}"
        "run();"
        "}catch(e){console.error('webmods js exec failed:',e);}})();";

  return ss.str();
}
