#pragma once

#include <filesystem>
#include <string>
#include <vector>

namespace lingosnap {

// Child process that is killed when the owner is destroyed (or the parent dies on Windows).
class ChildProcess {
 public:
  ChildProcess() = default;
  ~ChildProcess();
  ChildProcess(const ChildProcess&) = delete;
  ChildProcess& operator=(const ChildProcess&) = delete;

  bool Start(const std::filesystem::path& exe, const std::vector<std::string>& args,
             const std::vector<std::pair<std::string, std::string>>& env_prepend_path = {});
  bool Running();
  void Stop();

 private:
  struct State;
  State* state_ = nullptr;
};

}  // namespace lingosnap
