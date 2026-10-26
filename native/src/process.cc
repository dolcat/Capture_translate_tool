#include "process.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#else
#include <csignal>
#ifdef __linux__
#include <sys/prctl.h>
#endif
#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace lingosnap {

#ifdef _WIN32

struct ChildProcess::State {
  HANDLE process = nullptr;
  HANDLE job = nullptr;
};

namespace {
std::wstring Widen(const std::string& s) {
  if (s.empty()) return L"";
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), w.data(), n);
  return w;
}
}  // namespace

bool ChildProcess::Start(const std::filesystem::path& exe, const std::vector<std::string>& args,
                         const std::vector<std::pair<std::string, std::string>>& env) {
  Stop();
  std::wstring cmd = L"\"" + exe.wstring() + L"\"";
  for (const auto& a : args) cmd += L" \"" + Widen(a) + L"\"";
  for (const auto& [k, v] : env) {
    wchar_t old[32768];
    DWORD n = GetEnvironmentVariableW(Widen(k).c_str(), old, 32768);
    std::wstring value = Widen(v) + (n ? L";" + std::wstring(old, n) : L"");
    SetEnvironmentVariableW(Widen(k).c_str(), value.c_str());
  }
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  if (!CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE,
                      CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr, nullptr, &si, &pi))
    return false;
  state_ = new State;
  state_->process = pi.hProcess;
  state_->job = CreateJobObjectW(nullptr, nullptr);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION info{};
  info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  SetInformationJobObject(state_->job, JobObjectExtendedLimitInformation, &info, sizeof(info));
  AssignProcessToJobObject(state_->job, pi.hProcess);
  ResumeThread(pi.hThread);
  CloseHandle(pi.hThread);
  return true;
}

bool ChildProcess::Running() {
  return state_ && WaitForSingleObject(state_->process, 0) == WAIT_TIMEOUT;
}

void ChildProcess::Stop() {
  if (!state_) return;
  if (state_->job) CloseHandle(state_->job);  // kills the tree
  CloseHandle(state_->process);
  delete state_;
  state_ = nullptr;
}

#else

struct ChildProcess::State {
  pid_t pid = -1;
};

bool ChildProcess::Start(const std::filesystem::path& exe, const std::vector<std::string>& args,
                         const std::vector<std::pair<std::string, std::string>>& env) {
  Stop();
  std::vector<std::string> argv_s{exe.string()};
  argv_s.insert(argv_s.end(), args.begin(), args.end());
  std::vector<char*> argv;
  for (auto& s : argv_s) argv.push_back(s.data());
  argv.push_back(nullptr);
  pid_t pid = fork();
  if (pid < 0) return false;
  if (pid == 0) {
#ifdef __linux__
    prctl(PR_SET_PDEATHSIG, SIGTERM);  // do not outlive the backend
#endif
    int null_fd = open("/dev/null", O_RDWR);
    dup2(null_fd, 0);
    const char* log = getenv("LINGOSNAP_CHILD_LOG");  // diagnostics for the LanguageTool child
    int out_fd = log ? open(log, O_WRONLY | O_CREAT | O_APPEND, 0644) : null_fd;
    dup2(out_fd, 1); dup2(out_fd, 2);
    for (const auto& [k, v] : env) {
      const char* old = getenv(k.c_str());
      std::string value = v + (old ? ":" + std::string(old) : "");
      setenv(k.c_str(), value.c_str(), 1);
    }
    execvp(argv[0], argv.data());
    _exit(127);
  }
  state_ = new State;
  state_->pid = pid;
  return true;
}

bool ChildProcess::Running() {
  if (!state_) return false;
  return waitpid(state_->pid, nullptr, WNOHANG) == 0;
}

void ChildProcess::Stop() {
  if (!state_) return;
  kill(state_->pid, SIGTERM);
  waitpid(state_->pid, nullptr, 0);
  delete state_;
  state_ = nullptr;
}

#endif

ChildProcess::~ChildProcess() { Stop(); }

}  // namespace lingosnap
