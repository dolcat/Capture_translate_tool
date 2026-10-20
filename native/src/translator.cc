#include "translator.h"

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
  // Collapse line breaks into one sentence stream, as the Python backend did.
  std::string flat;
  flat.reserve(text.size());
  for (char c : text) flat.push_back(c == '\n' || c == '\r' ? ' ' : c);
  flat = Trim(flat);
  if (flat.empty()) return "";

  std::vector<std::string> pieces;
  auto status = impl_->sp.Encode(flat, &pieces);
  if (!status.ok()) throw std::runtime_error("Tokenize thất bại: " + status.ToString());

  ctranslate2::TranslationOptions options;
  options.beam_size = 2;
  options.max_decoding_length = 512;
  auto results = impl_->translator->translate_batch({pieces}, options);
  if (results.empty() || results[0].hypotheses.empty()) return "";

  std::string joined;
  for (const auto& tok : results[0].hypotheses[0]) joined += tok;
  std::string out;
  for (size_t i = 0; i < joined.size();) {
    if (joined.compare(i, 3, kSpaceMarker) == 0) { out.push_back(' '); i += 3; }
    else out.push_back(joined[i++]);
  }
  return Trim(out);
}

}  // namespace lingosnap
