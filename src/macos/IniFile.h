#ifndef INIFILE_H
#define INIFILE_H

#include <map>
#include <string>
#include <vector>

// Small case-insensitive INI reader/writer that keeps unknown keys, comments
// and ordering intact. Same semantics as the Win32 profile API used by the
// Windows build (GetPrivateProfileString/WritePrivateProfileString).
class IniFile {
public:
  explicit IniFile(std::string path);
  IniFile(const IniFile &) = delete;
  IniFile &operator=(const IniFile &) = delete;

  bool Load(); // false when the file does not exist yet
  bool Exists() const;

  std::string Get(const std::string &section, const std::string &key,
                  const std::string &defaultValue = "") const;
  int GetInt(const std::string &section, const std::string &key, int defaultValue) const;

  void Set(const std::string &section, const std::string &key, const std::string &value);
  bool Save();

  const std::string &Path() const { return path_; }

private:
  struct SectionRange {
    size_t headerLine = 0;
    size_t endLine = 0; // exclusive
  };

  size_t FindSectionInsertPos(const std::string &lowerSection) const;
  void ReindexFrom(size_t lineIndex, ptrdiff_t delta);

  std::string path_;
  std::vector<std::string> lines_;
  std::map<std::string, SectionRange> sections_;                  // lower name -> range
  std::map<std::string, std::map<std::string, size_t>> keys_;     // lower section -> lower key -> line
  bool loaded_ = false;
};

#endif // INIFILE_H
