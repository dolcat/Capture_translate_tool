#pragma once

#include <filesystem>
#include <mutex>
#include <string>
#include <vector>

#include "process.h"

namespace lingosnap {

// One problem LanguageTool found. Offsets count UTF-16 code units, like Dart strings.
struct GrammarMatch {
  size_t offset = 0, length = 0;
  std::string message, short_message, rule_id, category;
  std::vector<std::string> replacements;  // best first, at most 5
};

struct GrammarResult {
  std::string corrected;
  int issue_count = 0;
  std::vector<GrammarMatch> matches;
};

// Runs LanguageTool's HTTP server (Java) as a child process and applies the first
// replacement of every match, like language_tool_python.utils.correct.
class GrammarChecker {
 public:
  GrammarChecker(std::filesystem::path jar_path, std::filesystem::path java_dir);
  ~GrammarChecker() = default;

  bool jar_present() const;
  GrammarResult Check(const std::string& text);  // starts the server on first use

 private:
  void EnsureServer();

  std::filesystem::path jar_;
  std::filesystem::path java_dir_;  // bundled runtime root, may not exist
  int port_ = 0;
  ChildProcess process_;
  std::mutex mutex_;
};

}  // namespace lingosnap
