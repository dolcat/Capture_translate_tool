#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <nlohmann/json.hpp>
#include <string>
#include <vector>

#include "ocr.h"

namespace lingosnap {

struct LiveRegion {
  int x = 0, y = 0, w = 0, h = 0;
};

// "from" is replaced by "to" (case-insensitive, whole words when the term starts/ends
// with a letter or digit). In the "pre" list the term is also shielded from the translator,
// and an empty "to" means "keep the text exactly as it appears".
struct Replacement {
  std::string from, to;
};

struct LiveConfig {
  LiveRegion region;
  int interval_ms = 400;      // delay between screen captures
  int stable_ms = 300;        // text must stay the same this long before it is translated
  int clear_delay_ms = 1200;  // how long the overlay stays after the subtitle disappears
  int beam_size = 2;          // translation quality/speed trade-off (1 = fastest)
  std::vector<Replacement> pre;   // glossary: names/terms protected from translation
  std::vector<Replacement> post;  // fixes applied to the translated text

  bool overlay_enabled = true;
  std::string overlay_position = "cover";  // "cover" | "below" | "above"
  int font_size = 28;
  int opacity = 85;  // percent
  bool show_original = false;
  bool exclude_from_capture = true;  // keep the overlay out of our own screenshots
};

// Watches a screen region, OCRs it whenever the text changes, translates it, and shows the
// result in a click-through window drawn over the screen. Windows only.
class LiveTranslator {
 public:
  using OcrFn = std::function<std::vector<OcrLine>(const uint8_t* bgr, int w, int h, int stride)>;
  using TranslateFn = std::function<std::string(const std::string& text, int beam_size)>;

  LiveTranslator(OcrFn ocr, TranslateFn translate);
  ~LiveTranslator();

  // Starts (or restarts) with the JSON settings; absent keys keep their defaults.
  bool Start(const nlohmann::json& config, std::string& error);
  void Stop();
  // Applies new settings to a running session; absent keys keep their current value.
  bool Configure(const nlohmann::json& config, std::string& error);
  // Lets the user drag a rectangle on screen. Returns false with an empty error if cancelled.
  bool SelectRegion(LiveRegion& out, std::string& error);

  nlohmann::json Status() const;
  nlohmann::json History(int since_seq) const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace lingosnap
