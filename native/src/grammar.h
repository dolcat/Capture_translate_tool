#pragma once

#include <filesystem>
#include <mutex>
#include <string>

#include "process.h"

namespace lingosnap {

struct GrammarResult {
  std::string corrected;
  int issue_count = 0;
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
