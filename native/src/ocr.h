#pragma once

#include <filesystem>
#include <memory>
#include <string>
#include <vector>

namespace lingosnap {

struct OcrLine {
  std::string text;
  float score = 0.f;
  // Axis-aligned box in source image pixels: x0, y0, x1, y1.
  float box[4] = {0, 0, 0, 0};
  // A bullet mark (dot/square) sits just left of the box; the detector skips it.
  bool bullet = false;
};

// PP-OCRv5 mobile detection + English recognition running on ONNX Runtime.
// Mirrors the RapidOCR pipeline the Python backend used (no angle classifier).
class OcrEngine {
 public:
  OcrEngine(const std::filesystem::path& det_model,
            const std::filesystem::path& rec_model);
  ~OcrEngine();

  // Returns lines sorted top-to-bottom / left-to-right with score >= 0.5.
  std::vector<OcrLine> Recognize(const std::filesystem::path& image_path) const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace lingosnap
