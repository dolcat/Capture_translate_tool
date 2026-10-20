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

  std::string Translate(const std::string& text) const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace lingosnap
