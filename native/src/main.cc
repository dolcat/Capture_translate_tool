// LingoSnap native backend: same HTTP contract as the former backend/server.py.
//   GET /health, POST /analyze, POST /translate, POST /grammar, POST /grammar/warmup
#include <httplib.h>

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <iterator>
#include <iostream>
#include <memory>
#include <mutex>
#include <nlohmann/json.hpp>
#include <thread>

#include "grammar.h"
#include "ocr.h"
#include "translator.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#endif

using nlohmann::json;
namespace fs = std::filesystem;

namespace {

constexpr const char* kLanguageToolVersion = "6.8";

class Engines {
 public:
  Engines(fs::path models, fs::path java_dir) : models_(std::move(models)),
        grammar_(models_ / "languagetool" / (std::string("LanguageTool-") + kLanguageToolVersion) /
                     "languagetool-server.jar",
                 std::move(java_dir)) {}

  fs::path ocr_det() const { return models_ / "rapidocr" / "ch_PP-OCRv5_det_mobile.onnx"; }
  fs::path ocr_rec() const { return models_ / "rapidocr" / "en_PP-OCRv5_rec_mobile.onnx"; }
  fs::path mt_dir() const { return models_ / "argos-en-vi"; }

  bool models_ready() const {
    return fs::is_regular_file(ocr_det()) && fs::is_regular_file(ocr_rec()) &&
           fs::is_regular_file(mt_dir() / "model" / "model.bin") &&
           fs::is_regular_file(mt_dir() / "sentencepiece.model") && grammar_.jar_present();
  }
  bool ready() const { return ocr_ready_ && mt_ready_; }
  bool grammar_ready() const { return grammar_ready_; }
  std::string error() const { std::lock_guard l(err_mutex_); return error_; }

  lingosnap::OcrEngine& Ocr() {
    std::lock_guard lock(ocr_mutex_);
    if (!ocr_) Guard([&] {
      if (!fs::is_regular_file(ocr_det()) || !fs::is_regular_file(ocr_rec()))
        throw std::runtime_error("Thiếu model OCR ONNX. Hãy chạy tool\\setup_models.ps1.");
      ocr_ = std::make_unique<lingosnap::OcrEngine>(ocr_det(), ocr_rec());
      ocr_ready_ = true;
    });
    return *ocr_;
  }

  lingosnap::TextTranslator& Mt() {
    std::lock_guard lock(mt_mutex_);
    if (!mt_) Guard([&] {
      if (!fs::is_regular_file(mt_dir() / "model" / "model.bin"))
        throw std::runtime_error("Chưa có model dịch English→Vietnamese. Hãy chạy tool\\setup_models.ps1.");
      mt_ = std::make_unique<lingosnap::TextTranslator>(mt_dir());
      mt_ready_ = true;
    });
    return *mt_;
  }

  lingosnap::GrammarChecker& Grammar() { return grammar_; }
  void MarkGrammarReady() { grammar_ready_ = true; }

 private:
  template <typename F> void Guard(F&& f) {
    try { f(); std::lock_guard l(err_mutex_); error_.clear(); }
    catch (const std::exception& e) { std::lock_guard l(err_mutex_); error_ = e.what(); throw; }
  }

  fs::path models_;
  lingosnap::GrammarChecker grammar_;
  std::mutex ocr_mutex_, mt_mutex_;
  mutable std::mutex err_mutex_;
  std::unique_ptr<lingosnap::OcrEngine> ocr_;
  std::unique_ptr<lingosnap::TextTranslator> mt_;
  std::atomic<bool> ocr_ready_{false}, mt_ready_{false}, grammar_ready_{false};
  std::string error_;
};

void Fail(httplib::Response& res, int status, const std::string& detail) {
  res.status = status;
  res.set_content(json{{"detail", detail}}.dump(), "application/json; charset=utf-8");
}

void Ok(httplib::Response& res, const json& body) {
  res.set_content(body.dump(), "application/json; charset=utf-8");
}

bool ParseBody(const httplib::Request& req, httplib::Response& res, json& out) {
  out = json::parse(req.body, nullptr, false);
  if (out.is_discarded() || !out.is_object()) { Fail(res, 400, "Body JSON không hợp lệ."); return false; }
  return true;
}

bool IsEnVi(const json& b) {
  return b.value("sourceLanguage", "") == "en" && b.value("targetLanguage", "") == "vi";
}

fs::path Utf8Path(const std::string& s) { return fs::u8path(s); }

fs::path ExecutableDir() {
#ifdef _WIN32
  wchar_t buf[MAX_PATH * 4];
  DWORD n = GetModuleFileNameW(nullptr, buf, (DWORD)std::size(buf));
  return fs::path(std::wstring(buf, n)).parent_path();
#else
  return fs::canonical("/proc/self/exe").parent_path();
#endif
}

}  // namespace

int main(int argc, char** argv) {
  std::string host = "127.0.0.1";
  int port = 8765;
  fs::path models = ExecutableDir() / "models";
  if (const char* env = std::getenv("LINGOSNAP_MODELS"); env && *env) models = Utf8Path(env);
  std::string ocr_image;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto next = [&] { return i + 1 < argc ? std::string(argv[++i]) : std::string(); };
    if (a == "--host") host = next();
    else if (a == "--port") port = std::atoi(next().c_str());
    else if (a == "--models") models = Utf8Path(next());
    else if (a == "--ocr") ocr_image = next();  // debug: print OCR lines and exit
  }

  Engines engines(models, ExecutableDir() / "java");

  if (!ocr_image.empty()) {
    for (const auto& l : engines.Ocr().Recognize(Utf8Path(ocr_image)))
      std::cout << l.score << "\t[" << l.box[0] << "," << l.box[1] << "," << l.box[2] << ","
                << l.box[3] << "]\t" << l.text << "\n";
    return 0;
  }

  httplib::Server server;

  server.Get("/health", [&](const httplib::Request&, httplib::Response& res) {
    Ok(res, {{"ok", true}, {"ready", engines.ready()}, {"grammarReady", engines.grammar_ready()},
             {"packagesReady", true}, {"modelsReady", engines.models_ready()},
             {"error", engines.error().empty() ? json(nullptr) : json(engines.error())}});
  });

  server.Post("/analyze", [&](const httplib::Request& req, httplib::Response& res) {
    json b;
    if (!ParseBody(req, res, b)) return;
    if (!IsEnVi(b)) return Fail(res, 400, "MVP chỉ hỗ trợ English → Vietnamese.");
    fs::path image = Utf8Path(b.value("imagePath", ""));
    std::error_code ec;
    if (!fs::is_regular_file(image, ec))
      return Fail(res, 400, "Không tìm thấy ảnh: " + image.u8string());
    try {
      auto& mt = engines.Mt();
      auto lines = engines.Ocr().Recognize(image);
      if (lines.empty()) return Ok(res, {{"items", json::array()}});
      std::string original;
      double sum = 0;
      float box[4] = {1e30f, 1e30f, 0, 0};
      for (size_t i = 0; i < lines.size(); ++i) {
        original += (i ? "\n" : "") + lines[i].text;
        sum += lines[i].score;
        box[0] = std::min(box[0], lines[i].box[0]); box[1] = std::min(box[1], lines[i].box[1]);
        box[2] = std::max(box[2], lines[i].box[2]); box[3] = std::max(box[3], lines[i].box[3]);
      }
      Ok(res, {{"items", json::array({{{"original", original},
                                         {"translated", mt.Translate(original)},
                                         {"confidence", sum / lines.size()},
                                         {"box", {box[0], box[1], box[2], box[3]}}}})}});
    } catch (const std::exception& e) {
      Fail(res, 503, e.what());
    }
  });

  server.Post("/translate", [&](const httplib::Request& req, httplib::Response& res) {
    json b;
    if (!ParseBody(req, res, b)) return;
    if (!IsEnVi(b)) return Fail(res, 400, "MVP chỉ hỗ trợ English → Vietnamese.");
    std::string text = b.value("text", "");
    if (text.find_first_not_of(" \t\r\n") == std::string::npos)
      return Fail(res, 400, "Hãy nhập văn bản tiếng Anh cần dịch.");
    try {
      Ok(res, {{"translated", engines.Mt().Translate(text)}});
    } catch (const std::exception& e) {
      Fail(res, 503, e.what());
    }
  });

  auto grammar = [&](const std::string& text, httplib::Response& res, bool warmup) {
    try {
      auto r = engines.Grammar().Check(text);
      engines.MarkGrammarReady();
      if (warmup) return Ok(res, {{"ready", true}});
      Ok(res, {{"corrected", r.corrected}, {"issueCount", r.issue_count}});
    } catch (const std::exception& e) {
      Fail(res, 503, e.what());
    }
  };

  server.Post("/grammar", [&](const httplib::Request& req, httplib::Response& res) {
    json b;
    if (!ParseBody(req, res, b)) return;
    std::string text = b.value("text", "");
    if (text.find_first_not_of(" \t\r\n") == std::string::npos)
      return Fail(res, 400, "Hãy nhập hoặc dán văn bản tiếng Anh cần kiểm tra.");
    if (b.value("language", "en-US") != "en-US")
      return Fail(res, 400, "Kiểm tra ngữ pháp hiện chỉ hỗ trợ English (US).");
    grammar(text, res, false);
  });

  server.Post("/grammar/warmup", [&](const httplib::Request&, httplib::Response& res) {
    grammar("LanguageTool is ready.", res, true);
  });

  // Load OCR and translation in the background so the first request is fast.
  std::thread([&] {
    try { engines.Mt(); } catch (...) {}
    try { engines.Ocr(); } catch (...) {}
  }).detach();

  std::cout << "LingoSnap backend listening on " << host << ":" << port << std::endl;
  if (!server.listen(host, port)) {
    std::cerr << "Không mở được cổng " << port << std::endl;
    return 1;
  }
  return 0;
}
