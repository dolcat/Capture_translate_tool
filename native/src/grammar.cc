#include "grammar.h"

#include <httplib.h>

#ifndef _WIN32
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

#include <chrono>
#include <cstdlib>
#include <nlohmann/json.hpp>
#include <stdexcept>
#include <thread>

namespace lingosnap {
namespace {

std::u16string ToUtf16(const std::string& s) {
  std::u16string out;
  for (size_t i = 0; i < s.size();) {
    unsigned char c = s[i];
    char32_t cp;
    int n;
    if (c < 0x80) { cp = c; n = 1; }
    else if ((c >> 5) == 6) { cp = c & 0x1F; n = 2; }
    else if ((c >> 4) == 14) { cp = c & 0x0F; n = 3; }
    else { cp = c & 0x07; n = 4; }
    for (int k = 1; k < n && i + k < s.size(); ++k) cp = (cp << 6) | (s[i + k] & 0x3F);
    i += n;
    if (cp >= 0x10000) {
      cp -= 0x10000;
      out.push_back(static_cast<char16_t>(0xD800 + (cp >> 10)));
      out.push_back(static_cast<char16_t>(0xDC00 + (cp & 0x3FF)));
    } else out.push_back(static_cast<char16_t>(cp));
  }
  return out;
}

std::string ToUtf8(const std::u16string& s) {
  std::string out;
  for (size_t i = 0; i < s.size(); ++i) {
    char32_t cp = s[i];
    if (cp >= 0xD800 && cp < 0xDC00 && i + 1 < s.size()) {
      cp = 0x10000 + ((cp - 0xD800) << 10) + (s[++i] - 0xDC00);
    }
    if (cp < 0x80) out.push_back(static_cast<char>(cp));
    else if (cp < 0x800) {
      out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
      out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
      out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
      out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
      out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else {
      out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
      out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
      out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
      out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    }
  }
  return out;
}

// Asks the OS for a free loopback port, then releases it for the LanguageTool child.
int FindFreePort() {
#ifdef _WIN32
  WSADATA wsa;
  WSAStartup(MAKEWORD(2, 2), &wsa);
  using Sock = SOCKET;
  const Sock invalid = INVALID_SOCKET;
  auto close_sock = [](Sock s) { closesocket(s); };
  using Len = int;
#else
  using Sock = int;
  const Sock invalid = -1;
  auto close_sock = [](Sock s) { close(s); };
  using Len = socklen_t;
#endif
  Sock s = socket(AF_INET, SOCK_STREAM, 0);
  if (s == invalid) return 0;
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = 0;
  Len len = sizeof(addr);
  int port = 0;
  if (bind(s, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0 &&
      getsockname(s, reinterpret_cast<sockaddr*>(&addr), &len) == 0)
    port = ntohs(addr.sin_port);
  close_sock(s);
  return port;
}

}  // namespace

GrammarChecker::GrammarChecker(std::filesystem::path jar_path, std::filesystem::path java_dir)
    : jar_(std::move(jar_path)), java_dir_(std::move(java_dir)) {}

bool GrammarChecker::jar_present() const { return std::filesystem::is_regular_file(jar_); }

void GrammarChecker::EnsureServer() {
  if (process_.Running()) return;
  if (!jar_present())
    throw std::runtime_error("Thiếu LanguageTool. Hãy chạy tool\\setup_models.ps1.");

  std::filesystem::path java;
#ifdef _WIN32
  const char* exe_name = "java.exe";
#else
  const char* exe_name = "java";
#endif
  if (std::filesystem::is_regular_file(java_dir_ / "bin" / exe_name)) java = java_dir_ / "bin" / exe_name;
  else if (const char* home = std::getenv("JAVA_HOME"); home && std::filesystem::is_regular_file(std::filesystem::path(home) / "bin" / exe_name))
    java = std::filesystem::path(home) / "bin" / exe_name;
  else java = exe_name;  // PATH lookup

  port_ = FindFreePort();
  if (port_ <= 0) throw std::runtime_error("Không tìm được cổng trống cho LanguageTool.");
  if (!process_.Start(java, {"-cp", jar_.string(), "org.languagetool.server.HTTPServer",
                             "-p", std::to_string(port_)}))
    throw std::runtime_error("Không chạy được Java cho LanguageTool. Cần Java 17.");

  httplib::Client probe("127.0.0.1", port_);
  probe.set_connection_timeout(1);
  probe.set_read_timeout(5);
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(60);
  while (std::chrono::steady_clock::now() < deadline) {
    if (!process_.Running()) throw std::runtime_error("LanguageTool thoát đột ngột (kiểm tra Java 17).");
    if (auto res = probe.Get("/v2/languages"); res && res->status == 200) return;
    std::this_thread::sleep_for(std::chrono::milliseconds(250));
  }
  process_.Stop();
  throw std::runtime_error("LanguageTool khởi động quá lâu.");
}

GrammarResult GrammarChecker::Check(const std::string& text) {
  std::lock_guard lock(mutex_);
  EnsureServer();

  httplib::Client client("127.0.0.1", port_);
  client.set_read_timeout(120);
  auto res = client.Post("/v2/check", httplib::Params{{"language", "en-US"}, {"text", text}});
  if (!res || res->status != 200)
    throw std::runtime_error("LanguageTool trả về lỗi" +
                             (res ? " " + std::to_string(res->status) : std::string()));

  auto json = nlohmann::json::parse(res->body);
  std::u16string chars = ToUtf16(text);
  struct Edit { size_t off, len; std::u16string repl; };
  std::vector<Edit> edits;
  GrammarResult result;
  for (const auto& m : json.value("matches", nlohmann::json::array())) {
    const auto& reps = m.value("replacements", nlohmann::json::array());
    GrammarMatch gm;
    gm.offset = m.value("offset", 0);
    gm.length = m.value("length", 0);
    gm.message = m.value("message", "");
    gm.short_message = m.value("shortMessage", "");
    if (m.contains("rule") && m["rule"].is_object()) {
      gm.rule_id = m["rule"].value("id", "");
      if (m["rule"].contains("category") && m["rule"]["category"].is_object())
        gm.category = m["rule"]["category"].value("name", "");
    }
    for (const auto& r : reps) {
      if (gm.replacements.size() >= 5) break;
      if (r.contains("value") && r["value"].is_string()) gm.replacements.push_back(r["value"].get<std::string>());
    }
    result.matches.push_back(std::move(gm));
    if (reps.empty()) continue;
    edits.push_back({m.at("offset").get<size_t>(), m.at("length").get<size_t>(),
                     ToUtf16(reps[0].at("value").get<std::string>())});
  }
  result.issue_count = static_cast<int>(edits.size());
  long shift = 0;
  for (const auto& e : edits) {
    long from = static_cast<long>(e.off) + shift;
    if (from < 0 || static_cast<size_t>(from) + e.len > chars.size()) continue;
    chars.replace(static_cast<size_t>(from), e.len, e.repl);
    shift += static_cast<long>(e.repl.size()) - static_cast<long>(e.len);
  }
  result.corrected = ToUtf8(chars);
  return result;
}

}  // namespace lingosnap
