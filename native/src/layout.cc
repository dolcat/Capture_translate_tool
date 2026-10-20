#include "layout.h"

#include <algorithm>
#include <cctype>
#include <cmath>

namespace lingosnap {
namespace {

struct Row {
  std::string text;
  float x0, y0, x1, y1;
  bool bullet;
  float h() const { return y1 - y0; }
};

constexpr const char* kBullet = "\xE2\x80\xA2 ";  // "• "

bool StartsWith(const std::string& s, const char* prefix) {
  return s.compare(0, std::char_traits<char>::length(prefix), prefix) == 0;
}

// Glyphs used as bullets; OCR may glue them to the first word.
const char* const kGlyphs[] = {"\xE2\x80\xA2", "\xC2\xB7", "\xE2\x96\xAA", "\xE2\x97\xA6", "\xE2\x80\xA3",
                               "\xE2\x97\x8F", "\xE2\x97\x8B", "\xE2\x96\xA0", "\xE2\x96\xA1"};
// ASCII/dash markers count only when followed by a space.
const char* const kDashes[] = {"-", "*", "\xE2\x80\x93", "\xE2\x80\x94"};

bool IsBulletGlyph(const std::string& marker) {
  return marker.find_first_of("0123456789") == std::string::npos &&
         !(marker.size() >= 2 && std::islower(static_cast<unsigned char>(marker[0])));
}

std::string StripMarker(const std::string& text, std::string& marker) {
  marker = ListMarker(text);
  if (marker.empty()) return text;
  std::string rest = text.substr(marker.size());
  if (IsBulletGlyph(marker)) marker = kBullet;
  else if (marker.back() != ' ') marker += ' ';
  return rest;
}

bool StartsLower(const std::string& s) {
  return !s.empty() && std::islower(static_cast<unsigned char>(s[0]));
}

std::vector<Row> GroupRows(const std::vector<OcrLine>& lines) {
  std::vector<std::vector<const OcrLine*>> groups;
  for (const auto& l : lines) {
    float h = l.box[3] - l.box[1];
    bool placed = false;
    if (!groups.empty()) {
      auto& g = groups.back();
      float gy0 = 1e9f, gy1 = 0;
      for (auto* p : g) { gy0 = std::min(gy0, p->box[1]); gy1 = std::max(gy1, p->box[3]); }
      float overlap = std::min(gy1, l.box[3]) - std::max(gy0, l.box[1]);
      if (overlap > 0.5f * std::min(h, gy1 - gy0)) { g.push_back(&l); placed = true; }
    }
    if (!placed) groups.push_back({&l});
  }
  std::vector<Row> rows;
  for (auto& g : groups) {
    std::sort(g.begin(), g.end(), [](auto* a, auto* b) { return a->box[0] < b->box[0]; });
    Row r{"", 1e9f, 1e9f, 0, 0, g.front()->bullet};
    for (auto* p : g) {
      if (!r.text.empty()) r.text += ' ';
      r.text += p->text;
      r.x0 = std::min(r.x0, p->box[0]); r.y0 = std::min(r.y0, p->box[1]);
      r.x1 = std::max(r.x1, p->box[2]); r.y1 = std::max(r.y1, p->box[3]);
    }
    rows.push_back(std::move(r));
  }
  return rows;
}

}  // namespace

std::string ListMarker(const std::string& line) {
  for (const char* g : kGlyphs) {
    if (StartsWith(line, g)) {
      size_t n = std::char_traits<char>::length(g);
      while (n < line.size() && line[n] == ' ') ++n;
      return line.substr(0, n);
    }
  }
  for (const char* d : kDashes) {
    size_t n = std::char_traits<char>::length(d);
    if (StartsWith(line, d) && line.size() > n && line[n] == ' ') {
      while (n < line.size() && line[n] == ' ') ++n;
      return line.substr(0, n);
    }
  }
  // "1. ", "12) ", "a) "
  size_t i = 0;
  while (i < line.size() && i < 3 && std::isdigit(static_cast<unsigned char>(line[i]))) ++i;
  bool numbered = i > 0 && i < line.size() && (line[i] == '.' || line[i] == ')');
  bool lettered = i == 0 && line.size() > 1 && std::islower(static_cast<unsigned char>(line[0])) && line[1] == ')';
  if (lettered) i = 1;
  if ((numbered || lettered) && i + 1 < line.size() && line[i + 1] == ' ') {
    size_t n = i + 1;
    while (n < line.size() && line[n] == ' ') ++n;
    return line.substr(0, n);
  }
  return "";
}

std::vector<std::string> BuildParagraphs(const std::vector<OcrLine>& lines) {
  std::vector<Row> rows = GroupRows(lines);
  std::vector<std::string> paragraphs;
  const Row* prev = nullptr;
  float para_x0 = 0, para_right = 0;
  bool para_is_item = false;

  for (const auto& r : rows) {
    std::string marker;
    std::string text = StripMarker(r.text, marker);
    if (r.bullet && marker.empty()) marker = kBullet;

    bool start = prev == nullptr || !marker.empty();
    if (!start) {
      float h = std::min(prev->h(), r.h());
      float right = std::max(para_right, r.x1);
      start = r.y0 - prev->y1 > 0.7f * h                              // blank space between blocks
              || prev->x1 < right - 2.5f * h                         // previous line ended early
              || r.x0 < para_x0 - 0.6f * h                           // outdented
              || r.x0 > para_x0 + (para_is_item ? 3.f : 0.6f) * h    // indented
              || std::fabs(r.h() - prev->h()) > 0.35f * std::max(r.h(), prev->h());  // font size change
    }

    if (start) {
      paragraphs.push_back(marker + text);
      para_x0 = r.x0;
      para_right = r.x1;
      para_is_item = !marker.empty();
    } else {
      std::string& p = paragraphs.back();
      // Re-join words hyphenated across a line break ("auto-\nmation").
      if (p.size() >= 2 && p.back() == '-' && std::isalpha(static_cast<unsigned char>(p[p.size() - 2])) &&
          StartsLower(text)) {
        p.pop_back();
      } else {
        p += ' ';
      }
      p += text;
      para_right = std::max(para_right, r.x1);
    }
    prev = &r;
  }
  return paragraphs;
}

}  // namespace lingosnap
