#pragma once

#include <string>
#include <vector>

#include "ocr.h"

namespace lingosnap {

// Rebuilds paragraphs from OCR lines: lines on the same row are joined, wrapped
// lines are merged back into one paragraph, and list items start with "• ".
// Returns one string per paragraph, in reading order.
std::vector<std::string> BuildParagraphs(const std::vector<OcrLine>& lines);

// If `line` starts with a list marker ("•", "-", "1.", "a)"...), returns the
// marker including its trailing space; otherwise an empty string.
std::string ListMarker(const std::string& line);

}  // namespace lingosnap
