#pragma once

#include <filesystem>
#include <memory>
#include <string>

namespace lingosnap {

// English -> Vietnamese with SentencePiece + CTranslate2 (INT8, CPU). Two model layouts:
//   VinAI Translate en2vi v2 (mBART): model/ + sentencepiece.bpe.model
//   Argos (Marian):                   model/ + sentencepiece.model
// CTranslate2 uses LINGOSNAP_MT_THREADS threads (default 2, so games keep their CPU).
class TextTranslator {
 public:
  explicit TextTranslator(const std::filesystem::path& model_dir);
  ~TextTranslator();

  // beam_size 1 is fastest; larger values are slower but usually better.
  std::string Translate(const std::string& text, int beam_size = 2) const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace lingosnap
