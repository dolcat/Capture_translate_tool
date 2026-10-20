#pragma once

#include <filesystem>
#include <memory>
#include <string>

namespace lingosnap {

// Argos English -> Vietnamese model: SentencePiece tokenizer + CTranslate2 (INT8, CPU).
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
