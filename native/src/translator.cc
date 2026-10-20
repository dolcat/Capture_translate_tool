#include "translator.h"

#include "layout.h"

#include <ctranslate2/translator.h>
#include <sentencepiece_processor.h>

#include <stdexcept>
#include <vector>

namespace lingosnap {
namespace {

constexpr const char* kSpaceMarker = "\xE2\x96\x81";  // U+2581

std::string Trim(const std::string& s) {
  auto b = s.find_first_not_of(" \t\r\n");
  if (b == std::string::npos) return "";
  return s.substr(b, s.find_last_not_of(" \t\r\n") - b + 1);
}

}  // namespace

struct TextTranslator::Impl {
  sentencepiece::SentencePieceProcessor sp;
  std::unique_ptr<ctranslate2::Translator> translator;
};

TextTranslator::TextTranslator(const std::filesystem::path& model_dir)
    : impl_(std::make_unique<Impl>()) {
  auto status = impl_->sp.Load((model_dir / "sentencepiece.model").string());
  if (!status.ok()) throw std::runtime_error("Không nạp được sentencepiece.model: " + status.ToString());
  ctranslate2::ReplicaPoolConfig pool;
  pool.num_threads_per_replica = 0;  // CTranslate2 default (physical cores)
  impl_->translator = std::make_unique<ctranslate2::Translator>(
      (model_dir / "model").string(), ctranslate2::Device::CPU, ctranslate2::ComputeType::INT8,
      std::vector<int>{0}, false, pool);
}

TextTranslator::~TextTranslator() = default;

std::string TextTranslator::Translate(const std::string& text) const {
  // Each line is a paragraph or list item: translate them separately (in one batch)
  // and keep line breaks and list markers, so the result has the same layout.
  struct Line { std::string marker; int batch_index = -1; };
  std::vector<Line> lines;
  std::vector<std::vector<std::string>> batch;
  size_t start = 0;
  while (start <= text.size()) {
    size_t end = text.find('\n', start);
    if (end == std::string::npos) end = text.size();
    std::string line = Trim(text.substr(start, end - start));
    start = end + 1;
    Line l;
    l.marker = ListMarker(line);
    std::string content = Trim(line.substr(l.marker.size()));
    if (!content.empty()) {
      std::vector<std::string> pieces;
      auto status = impl_->sp.Encode(content, &pieces);
      if (!status.ok()) throw std::runtime_error("Tokenize thất bại: " + status.ToString());
      l.batch_index = static_cast<int>(batch.size());
      batch.push_back(std::move(pieces));
    }
    lines.push_back(std::move(l));
  }
  if (batch.empty()) return "";

  ctranslate2::TranslationOptions options;
  options.beam_size = 2;
  options.max_decoding_length = 512;
  auto results = impl_->translator->translate_batch(batch, options);

  std::vector<std::string> translated(batch.size());
  for (size_t b = 0; b < results.size() && b < batch.size(); ++b) {
    if (results[b].hypotheses.empty()) continue;
    std::string joined;
    for (const auto& tok : results[b].hypotheses[0]) joined += tok;
    std::string out;
    for (size_t i = 0; i < joined.size();) {
      if (joined.compare(i, 3, kSpaceMarker) == 0) { out.push_back(' '); i += 3; }
      else out.push_back(joined[i++]);
    }
    translated[b] = Trim(out);
  }

  std::string result;
  for (size_t i = 0; i < lines.size(); ++i) {
    if (i) result += '\n';
    result += lines[i].marker;
    if (lines[i].batch_index >= 0) result += translated[lines[i].batch_index];
  }
  return Trim(result);
}

}  // namespace lingosnap
