#include "IniFile.h"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>

namespace {

std::string Trim(const std::string &s) {
  size_t a = s.find_first_not_of(" \t\r\n");
  if (a == std::string::npos) return {};
  size_t b = s.find_last_not_of(" \t\r\n");
  return s.substr(a, b - a + 1);
}

std::string Lower(const std::string &s) {
  std::string out = s;
  for (auto &c : out) c = (char)tolower((unsigned char)c);
  return out;
}

} // namespace

IniFile::IniFile(std::string path) : path_(std::move(path)) {}

bool IniFile::Exists() const {
  std::error_code ec;
  return std::filesystem::is_regular_file(path_, ec);
}

bool IniFile::Load() {
  lines_.clear();
  sections_.clear();
  keys_.clear();

  std::ifstream f(path_);
  if (!f) {
    loaded_ = true;
    return false;
  }

  std::string line;
  bool first = true;
  while (std::getline(f, line)) {
    if (first) {
      first = false;
      if (line.size() >= 3 && (unsigned char)line[0] == 0xEF && (unsigned char)line[1] == 0xBB &&
          (unsigned char)line[2] == 0xBF) {
        line.erase(0, 3);
      }
    }
    if (!line.empty() && line.back() == '\r') line.pop_back();
    lines_.push_back(line);
  }

  std::string currentSection;
  for (size_t i = 0; i < lines_.size(); ++i) {
    std::string trimmed = Trim(lines_[i]);
    if (trimmed.empty() || trimmed[0] == ';' || trimmed[0] == '#') continue;

    if (trimmed.front() == '[' && trimmed.back() == ']') {
      currentSection = Lower(Trim(trimmed.substr(1, trimmed.size() - 2)));
      auto &range = sections_[currentSection];
      range.headerLine = i;
      range.endLine = lines_.size();
      continue;
    }

    size_t eq = trimmed.find('=');
    if (eq == std::string::npos || currentSection.empty()) continue;

    std::string key = Lower(Trim(trimmed.substr(0, eq)));
    if (key.empty()) continue;

    if (keys_[currentSection].find(key) == keys_[currentSection].end()) {
      keys_[currentSection][key] = i;
    }
  }

  // Section end = next section header line (or EOF).
  for (auto &[name, range] : sections_) {
    for (const auto &[otherName, otherRange] : sections_) {
      if (otherRange.headerLine > range.headerLine && otherRange.headerLine < range.endLine) {
        range.endLine = otherRange.headerLine;
      }
    }
    (void)name;
  }

  loaded_ = true;
  return true;
}

std::string IniFile::Get(const std::string &section, const std::string &key,
                         const std::string &defaultValue) const {
  auto secIt = keys_.find(Lower(section));
  if (secIt == keys_.end()) return defaultValue;
  auto keyIt = secIt->second.find(Lower(key));
  if (keyIt == secIt->second.end()) return defaultValue;

  const std::string &line = lines_[keyIt->second];
  size_t eq = line.find('=');
  if (eq == std::string::npos) return defaultValue;
  return Trim(line.substr(eq + 1));
}

int IniFile::GetInt(const std::string &section, const std::string &key, int defaultValue) const {
  std::string value = Get(section, key);
  if (value.empty()) return defaultValue;
  char *end = nullptr;
  long parsed = std::strtol(value.c_str(), &end, 10);
  if (end == value.c_str() || *end != '\0') return defaultValue;
  return (int)parsed;
}

void IniFile::ReindexFrom(size_t lineIndex, ptrdiff_t delta) {
  for (auto &[name, range] : sections_) {
    if (range.headerLine >= lineIndex) range.headerLine += delta;
    if (range.endLine >= lineIndex) range.endLine += delta;
  }
  for (auto &[section, keyMap] : keys_) {
    for (auto &[key, line] : keyMap) {
      if (line >= lineIndex) line += delta;
    }
  }
}

size_t IniFile::FindSectionInsertPos(const std::string &lowerSection) const {
  auto it = sections_.find(lowerSection);
  if (it != sections_.end()) {
    // Insert before trailing blank lines of the section, like most INI editors.
    size_t pos = it->second.endLine;
    while (pos > it->second.headerLine + 1 && Trim(lines_[pos - 1]).empty()) pos--;
    return pos;
  }
  return lines_.size();
}

void IniFile::Set(const std::string &section, const std::string &key, const std::string &value) {
  if (!loaded_) Load();

  const std::string lowerSection = Lower(section);
  const std::string lowerKey = Lower(key);
  const std::string newLine = key + "=" + value;

  auto secIt = keys_.find(lowerSection);
  if (secIt != keys_.end()) {
    auto keyIt = secIt->second.find(lowerKey);
    if (keyIt != secIt->second.end()) {
      lines_[keyIt->second] = newLine;
      return;
    }
  }

  auto sectionIt = sections_.find(lowerSection);
  if (sectionIt == sections_.end()) {
    if (!lines_.empty() && !lines_.back().empty()) lines_.push_back("");
    size_t headerLine = lines_.size();
    lines_.push_back("[" + section + "]");
    size_t valueLine = lines_.size();
    lines_.push_back(newLine);
    sections_[lowerSection] = SectionRange{headerLine, lines_.size()};
    keys_[lowerSection][lowerKey] = valueLine;
    return;
  }

  size_t pos = FindSectionInsertPos(lowerSection);
  lines_.insert(lines_.begin() + (ptrdiff_t)pos, newLine);
  ReindexFrom(pos, 1);
  keys_[lowerSection][lowerKey] = pos;
}

bool IniFile::Save() {
  if (!loaded_) Load();

  std::error_code ec;
  std::filesystem::path target(path_);
  if (!target.parent_path().empty()) {
    std::filesystem::create_directories(target.parent_path(), ec);
  }

  std::filesystem::path temp = target;
  temp += ".tmp";

  {
    std::ofstream f(temp, std::ios::binary | std::ios::trunc);
    if (!f) return false;
    for (size_t i = 0; i < lines_.size(); ++i) {
      f << lines_[i] << "\n";
    }
    if (!f.good()) return false;
  }

  std::filesystem::rename(temp, target, ec);
  if (ec) {
    std::filesystem::remove(target, ec);
    ec.clear();
    std::filesystem::rename(temp, target, ec);
  }
  return !ec;
}
