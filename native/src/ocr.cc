#include "ocr.h"

#include <onnxruntime_cxx_api.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <numeric>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#include <stdexcept>

namespace lingosnap {
namespace {

constexpr int kMaxSideLen = 2000;
constexpr int kMinSideLen = 30;
constexpr float kDetThresh = 0.3f;
constexpr float kBoxThresh = 0.5f;
constexpr float kUnclipRatio = 1.6f;
constexpr size_t kMaxCandidates = 1000;
constexpr float kTextScore = 0.5f;
constexpr int kRecBatch = 6;
constexpr int kRecH = 48;
constexpr int kRecW = 320;

using Quad = std::array<cv::Point2f, 4>;

int RoundTo32(double v) { return static_cast<int>(std::lround(v / 32.0) * 32); }

cv::Mat LoadImage(const std::filesystem::path& path) {
  std::ifstream file(path, std::ios::binary);
  if (!file) throw std::runtime_error("Không mở được ảnh: " + path.string());
  std::vector<uchar> bytes((std::istreambuf_iterator<char>(file)),
                           std::istreambuf_iterator<char>());
  cv::Mat img = cv::imdecode(bytes, cv::IMREAD_COLOR);  // BGR, like RapidOCR
  if (img.empty()) throw std::runtime_error("Không đọc được ảnh: " + path.string());
  return img;
}

// Looks for a lone, roughly square blob (•, ▪, ◦) in the strip left of a text box.
// Small marks like these are usually not picked up by the text detector.
bool HasBulletMark(const cv::Mat& gray, const float box[4]) {
  float h = box[3] - box[1];
  int x0 = std::max(0, static_cast<int>(box[0] - 1.6f * h));
  int x1 = std::min(gray.cols, static_cast<int>(box[0]));
  int y0 = std::max(0, static_cast<int>(box[1]));
  int y1 = std::min(gray.rows, static_cast<int>(box[3]));
  if (x1 - x0 < 4 || y1 - y0 < 4) return false;

  cv::Mat roi = gray(cv::Rect(x0, y0, x1 - x0, y1 - y0));
  std::vector<uchar> px(roi.begin<uchar>(), roi.end<uchar>());
  std::nth_element(px.begin(), px.begin() + px.size() / 2, px.end());
  int background = px[px.size() / 2];
  cv::Mat diff, mask;
  cv::absdiff(roi, cv::Scalar(background), diff);
  cv::threshold(diff, mask, 60, 255, cv::THRESH_BINARY);

  cv::Mat labels, stats, centroids;
  int n = cv::connectedComponentsWithStats(mask, labels, stats, centroids, 8);
  int found = 0, other = 0;
  for (int i = 1; i < n; ++i) {
    int w = stats.at<int>(i, cv::CC_STAT_WIDTH), ht = stats.at<int>(i, cv::CC_STAT_HEIGHT);
    int area = stats.at<int>(i, cv::CC_STAT_AREA);
    if (area < 3) continue;  // noise
    float aspect = static_cast<float>(w) / ht;
    float cy = static_cast<float>(centroids.at<double>(i, 1)) / (y1 - y0);
    bool mark = w >= 0.12f * h && w <= 0.6f * h && ht >= 0.12f * h && ht <= 0.6f * h &&
                aspect > 0.6f && aspect < 1.6f && cy > 0.25f && cy < 0.75f;
    (mark ? found : other)++;
  }
  return found == 1 && other == 0;
}

// RapidOCR resize_image_within_bounds: only touches images outside [30, 2000].
cv::Mat ResizeWithinBounds(const cv::Mat& src, double& ratio_h, double& ratio_w) {
  ratio_h = ratio_w = 1.0;
  cv::Mat img = src;
  auto rescale = [&](double ratio) {
    int h = img.rows, w = img.cols;
    int rh = RoundTo32(static_cast<int>(h * ratio));
    int rw = RoundTo32(static_cast<int>(w * ratio));
    if (rh <= 0 || rw <= 0) throw std::runtime_error("Kích thước ảnh không hợp lệ");
    cv::Mat out;
    cv::resize(img, out, cv::Size(rw, rh));
    ratio_h = static_cast<double>(h) / rh;
    ratio_w = static_cast<double>(w) / rw;
    img = out;
  };
  if (std::max(img.rows, img.cols) > kMaxSideLen)
    rescale(static_cast<double>(kMaxSideLen) / std::max(img.rows, img.cols));
  if (std::min(img.rows, img.cols) < kMinSideLen)
    rescale(static_cast<double>(kMinSideLen) / std::min(img.rows, img.cols));
  return img;
}

// get_mini_boxes: minAreaRect corners ordered tl, tr, br, bl; returns short side.
Quad MiniBox(const std::vector<cv::Point2f>& pts, float& short_side) {
  cv::RotatedRect rect = cv::minAreaRect(pts);
  cv::Point2f corners[4];
  rect.points(corners);
  std::vector<cv::Point2f> p(corners, corners + 4);
  std::sort(p.begin(), p.end(),
            [](const cv::Point2f& a, const cv::Point2f& b) { return a.x < b.x; });
  int i1, i2, i3, i4;
  if (p[1].y > p[0].y) { i1 = 0; i4 = 1; } else { i1 = 1; i4 = 0; }
  if (p[3].y > p[2].y) { i2 = 2; i3 = 3; } else { i2 = 3; i3 = 2; }
  short_side = std::min(rect.size.width, rect.size.height);
  return {p[i1], p[i2], p[i3], p[i4]};
}

float BoxScoreFast(const cv::Mat& prob, const Quad& box) {
  int h = prob.rows, w = prob.cols;
  float minx = box[0].x, maxx = box[0].x, miny = box[0].y, maxy = box[0].y;
  for (const auto& p : box) {
    minx = std::min(minx, p.x); maxx = std::max(maxx, p.x);
    miny = std::min(miny, p.y); maxy = std::max(maxy, p.y);
  }
  int xmin = std::clamp(static_cast<int>(std::floor(minx)), 0, w - 1);
  int xmax = std::clamp(static_cast<int>(std::ceil(maxx)), 0, w - 1);
  int ymin = std::clamp(static_cast<int>(std::floor(miny)), 0, h - 1);
  int ymax = std::clamp(static_cast<int>(std::ceil(maxy)), 0, h - 1);
  cv::Mat mask = cv::Mat::zeros(ymax - ymin + 1, xmax - xmin + 1, CV_8UC1);
  std::vector<cv::Point> poly;
  for (const auto& p : box)
    poly.emplace_back(static_cast<int>(p.x - xmin), static_cast<int>(p.y - ymin));
  cv::fillPoly(mask, std::vector<std::vector<cv::Point>>{poly}, cv::Scalar(1));
  return static_cast<float>(
      cv::mean(prob(cv::Rect(xmin, ymin, xmax - xmin + 1, ymax - ymin + 1)), mask)[0]);
}

// DB unclip. The candidate is a rectangle, so offsetting it with round joins and
// taking the min-area rectangle again equals growing every side by `distance`.
std::vector<cv::Point2f> Unclip(const Quad& box) {
  double area = std::fabs(cv::contourArea(std::vector<cv::Point2f>(box.begin(), box.end())));
  double perimeter = cv::arcLength(std::vector<cv::Point2f>(box.begin(), box.end()), true);
  double d = perimeter > 0 ? area * kUnclipRatio / perimeter : 0.0;
  cv::Point2f c(0, 0);
  for (const auto& p : box) c += p;
  c *= 0.25f;
  cv::Point2f u = box[1] - box[0], v = box[3] - box[0];
  double lu = std::hypot(u.x, u.y), lv = std::hypot(v.x, v.y);
  if (lu > 0) u *= static_cast<float>(1.0 / lu);
  if (lv > 0) v *= static_cast<float>(1.0 / lv);
  double hw = lu / 2 + d, hh = lv / 2 + d;
  std::vector<cv::Point2f> out;
  for (auto [sx, sy] : {std::pair{-1, -1}, {1, -1}, {1, 1}, {-1, 1}})
    out.push_back(c + u * static_cast<float>(sx * hw) + v * static_cast<float>(sy * hh));
  return out;
}

// order_points_clockwise + clip_det_res (integer truncation like the original).
Quad OrderAndClip(const Quad& in, int h, int w) {
  std::array<cv::Point2f, 4> p = in;
  std::sort(p.begin(), p.end(),
            [](const cv::Point2f& a, const cv::Point2f& b) { return a.x < b.x; });
  cv::Point2f tl = p[0], bl = p[1], tr = p[2], br = p[3];
  if (bl.y < tl.y) std::swap(tl, bl);
  if (br.y < tr.y) std::swap(tr, br);
  Quad q = {tl, tr, br, bl};
  for (auto& pt : q) {
    pt.x = static_cast<float>(static_cast<int>(std::min(std::max(pt.x, 0.f), static_cast<float>(w - 1))));
    pt.y = static_cast<float>(static_cast<int>(std::min(std::max(pt.y, 0.f), static_cast<float>(h - 1))));
  }
  return q;
}

float Dist(const cv::Point2f& a, const cv::Point2f& b) { return std::hypot(a.x - b.x, a.y - b.y); }

cv::Mat CropQuad(const cv::Mat& img, const Quad& q) {
  int cw = static_cast<int>(std::max(Dist(q[0], q[1]), Dist(q[2], q[3])));
  int ch = static_cast<int>(std::max(Dist(q[0], q[3]), Dist(q[1], q[2])));
  cv::Point2f src[4] = {q[0], q[1], q[2], q[3]};
  cv::Point2f dst[4] = {{0, 0}, {static_cast<float>(cw), 0},
                        {static_cast<float>(cw), static_cast<float>(ch)},
                        {0, static_cast<float>(ch)}};
  cv::Mat m = cv::getPerspectiveTransform(src, dst);
  cv::Mat out;
  cv::warpPerspective(img, out, m, cv::Size(cw, ch), cv::INTER_CUBIC, cv::BORDER_REPLICATE);
  if (static_cast<double>(out.rows) / out.cols >= 1.5) {
    cv::Mat rot;
    cv::rotate(out, rot, cv::ROTATE_90_COUNTERCLOCKWISE);  // np.rot90
    out = rot;
  }
  return out;
}

// Same splitting as Python's str.splitlines(): the model's character list is stored
// as one string, and a trailing line break must not create an extra empty entry
// (that would shift the space/blank indices and drop every space from the output).
std::vector<std::string> SplitLines(const std::string& s) {
  std::vector<std::string> out;
  std::string cur;
  auto starts = [&](size_t i, const char* seq) { return s.compare(i, std::strlen(seq), seq) == 0; };
  for (size_t i = 0; i < s.size();) {
    unsigned char c = s[i];
    size_t skip = 0;
    if (c == '\r') skip = (i + 1 < s.size() && s[i + 1] == '\n') ? 2 : 1;
    else if (c == '\n' || c == 0x0b || c == 0x0c || c == 0x1c || c == 0x1d || c == 0x1e) skip = 1;
    else if (starts(i, "\xC2\x85")) skip = 2;                                  // U+0085
    else if (starts(i, "\xE2\x80\xA8") || starts(i, "\xE2\x80\xA9")) skip = 3;  // U+2028/2029
    if (skip) { out.push_back(cur); cur.clear(); i += skip; }
    else { cur.push_back(static_cast<char>(c)); ++i; }
  }
  if (!cur.empty()) out.push_back(cur);
  return out;
}

struct Detected {
  Quad quad;
  float score;
};

}  // namespace

struct OcrEngine::Impl {
  Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "lingosnap"};
  Ort::SessionOptions options;
  std::unique_ptr<Ort::Session> det, rec;
  std::string det_in, det_out, rec_in, rec_out;
  std::vector<std::string> dict;  // index 0 = CTC blank, last = space

  static std::string Name(Ort::Session& s, bool input) {
    Ort::AllocatorWithDefaultOptions alloc;
    auto n = input ? s.GetInputNameAllocated(0, alloc) : s.GetOutputNameAllocated(0, alloc);
    return n.get();
  }

  Impl(const std::filesystem::path& det_path, const std::filesystem::path& rec_path) {
    options.SetIntraOpNumThreads(0);
    options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
    options.DisableCpuMemArena();
    det = std::make_unique<Ort::Session>(env, det_path.c_str(), options);
    rec = std::make_unique<Ort::Session>(env, rec_path.c_str(), options);
    det_in = Name(*det, true); det_out = Name(*det, false);
    rec_in = Name(*rec, true); rec_out = Name(*rec, false);

    Ort::AllocatorWithDefaultOptions alloc;
    Ort::ModelMetadata meta = rec->GetModelMetadata();
    auto chars = meta.LookupCustomMetadataMapAllocated("character", alloc);
    if (!chars) throw std::runtime_error("Model nhận dạng thiếu metadata 'character'");
    dict = SplitLines(chars.get());
    dict.insert(dict.begin(), "blank");
    dict.push_back(" ");

    // The recognizer's class axis must equal blank + characters + space.
    auto classes = rec->GetOutputTypeInfo(0).GetTensorTypeAndShapeInfo().GetShape().back();
    if (classes > 0 && classes != static_cast<int64_t>(dict.size()))
      std::cerr << "Cảnh báo: từ điển OCR có " << dict.size() << " mục nhưng model có "
                << classes << " lớp; kết quả có thể sai.\n";
  }

  std::vector<Detected> Detect(const cv::Mat& img) const {
    const int src_h = img.rows, src_w = img.cols;
    int max_wh = std::max(src_h, src_w);
    int limit = max_wh < 960 ? 960 : (max_wh < 1500 ? 1500 : 2000);
    double ratio = max_wh > limit ? static_cast<double>(limit) / max_wh : 1.0;
    int rh = RoundTo32(static_cast<int>(src_h * ratio));
    int rw = RoundTo32(static_cast<int>(src_w * ratio));
    if (rh <= 0 || rw <= 0) return {};

    cv::Mat resized;
    cv::resize(img, resized, cv::Size(rw, rh));
    std::vector<float> input(3 * rh * rw);
    for (int y = 0; y < rh; ++y) {
      const uchar* row = resized.ptr<uchar>(y);
      for (int x = 0; x < rw; ++x)
        for (int c = 0; c < 3; ++c)
          input[(c * rh + y) * rw + x] = (row[x * 3 + c] / 255.f - 0.5f) / 0.5f;
    }
    std::array<int64_t, 4> shape = {1, 3, rh, rw};
    auto mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    Ort::Value tensor = Ort::Value::CreateTensor<float>(mem, input.data(), input.size(),
                                                        shape.data(), shape.size());
    const char* in_names[] = {det_in.c_str()};
    const char* out_names[] = {det_out.c_str()};
    auto out = det->Run(Ort::RunOptions{nullptr}, in_names, &tensor, 1, out_names, 1);
    auto info = out[0].GetTensorTypeAndShapeInfo();
    auto oshape = info.GetShape();  // 1,1,H,W
    int ph = static_cast<int>(oshape[2]), pw = static_cast<int>(oshape[3]);
    cv::Mat prob(ph, pw, CV_32FC1, out[0].GetTensorMutableData<float>());

    cv::Mat bitmap = prob > kDetThresh;  // 0/255
    cv::Mat dilated;
    cv::dilate(bitmap, dilated, cv::Mat::ones(2, 2, CV_8UC1));  // 2x2 kernel, anchor (1,1) like numpy path
    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(dilated, contours, cv::RETR_LIST, cv::CHAIN_APPROX_SIMPLE);

    std::vector<Detected> result;
    size_t n = std::min(contours.size(), kMaxCandidates);
    for (size_t i = 0; i < n; ++i) {
      std::vector<cv::Point2f> c(contours[i].begin(), contours[i].end());
      if (c.size() < 3) continue;
      float side;
      Quad box = MiniBox(c, side);
      if (side < 3) continue;
      float score = BoxScoreFast(prob, box);
      if (score < kBoxThresh) continue;
      Quad ex = MiniBox(Unclip(box), side);
      if (side < 5) continue;
      for (auto& p : ex) {
        p.x = std::clamp(std::round(p.x / pw * src_w), 0.f, static_cast<float>(src_w));
        p.y = std::clamp(std::round(p.y / ph * src_h), 0.f, static_cast<float>(src_h));
      }
      ex = OrderAndClip(ex, src_h, src_w);
      if (static_cast<int>(Dist(ex[0], ex[1])) <= 3 || static_cast<int>(Dist(ex[0], ex[3])) <= 3)
        continue;
      result.push_back({ex, score});
    }

    // Reading order: stable sort by top-left y, group rows within 10px, then x.
    std::stable_sort(result.begin(), result.end(), [](const Detected& a, const Detected& b) {
      return a.quad[0].y < b.quad[0].y;
    });
    std::vector<int> line(result.size(), 0);
    for (size_t i = 1; i < result.size(); ++i)
      line[i] = line[i - 1] + (result[i].quad[0].y - result[i - 1].quad[0].y >= 10 ? 1 : 0);
    std::vector<size_t> idx(result.size());
    std::iota(idx.begin(), idx.end(), 0);
    std::stable_sort(idx.begin(), idx.end(), [&](size_t a, size_t b) {
      if (line[a] != line[b]) return line[a] < line[b];
      return result[a].quad[0].x < result[b].quad[0].x;
    });
    std::vector<Detected> sorted;
    for (size_t i : idx) sorted.push_back(result[i]);
    return sorted;
  }

  std::vector<std::pair<std::string, float>> Recognize(const std::vector<cv::Mat>& crops) const {
    std::vector<std::pair<std::string, float>> res(crops.size(), {"", 0.f});
    std::vector<size_t> order(crops.size());
    std::iota(order.begin(), order.end(), 0);
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) {
      return static_cast<double>(crops[a].cols) / crops[a].rows <
             static_cast<double>(crops[b].cols) / crops[b].rows;
    });

    for (size_t beg = 0; beg < order.size(); beg += kRecBatch) {
      size_t end = std::min(order.size(), beg + kRecBatch);
      double max_ratio = static_cast<double>(kRecW) / kRecH;
      for (size_t i = beg; i < end; ++i) {
        const cv::Mat& m = crops[order[i]];
        max_ratio = std::max(max_ratio, static_cast<double>(m.cols) / m.rows);
      }
      int width = static_cast<int>(kRecH * max_ratio);
      size_t batch = end - beg;
      std::vector<float> input(batch * 3 * kRecH * width, 0.f);
      for (size_t b = 0; b < batch; ++b) {
        const cv::Mat& m = crops[order[beg + b]];
        double ratio = static_cast<double>(m.cols) / m.rows;
        int rw = std::ceil(kRecH * ratio) > width ? width : static_cast<int>(std::ceil(kRecH * ratio));
        cv::Mat r;
        cv::resize(m, r, cv::Size(rw, kRecH));
        float* base = input.data() + b * 3 * kRecH * width;
        for (int y = 0; y < kRecH; ++y) {
          const uchar* row = r.ptr<uchar>(y);
          for (int x = 0; x < rw; ++x)
            for (int c = 0; c < 3; ++c)
              base[(c * kRecH + y) * width + x] = (row[x * 3 + c] / 255.f - 0.5f) / 0.5f;
        }
      }
      std::array<int64_t, 4> shape = {static_cast<int64_t>(batch), 3, kRecH, width};
      auto mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
      Ort::Value tensor = Ort::Value::CreateTensor<float>(mem, input.data(), input.size(),
                                                          shape.data(), shape.size());
      const char* in_names[] = {rec_in.c_str()};
      const char* out_names[] = {rec_out.c_str()};
      auto out = rec->Run(Ort::RunOptions{nullptr}, in_names, &tensor, 1, out_names, 1);
      auto oshape = out[0].GetTensorTypeAndShapeInfo().GetShape();  // B,T,C
      int64_t steps = oshape[1], classes = oshape[2];
      const float* data = out[0].GetTensorData<float>();
      for (size_t b = 0; b < batch; ++b) {
        std::string text;
        double sum = 0;
        int count = 0;
        int64_t prev = -1;
        for (int64_t t = 0; t < steps; ++t) {
          const float* p = data + (b * steps + t) * classes;
          int64_t best = std::max_element(p, p + classes) - p;
          if (best != prev && best != 0 && best < static_cast<int64_t>(dict.size())) {
            text += dict[best];
            sum += p[best];
            ++count;
          }
          prev = best;
        }
        res[order[beg + b]] = {text, count ? static_cast<float>(sum / count) : 0.f};
      }
    }
    return res;
  }
};

OcrEngine::OcrEngine(const std::filesystem::path& det, const std::filesystem::path& rec)
    : impl_(std::make_unique<Impl>(det, rec)) {}
OcrEngine::~OcrEngine() = default;

std::vector<OcrLine> OcrEngine::Recognize(const std::filesystem::path& image_path) const {
  cv::Mat original = LoadImage(image_path);
  double ratio_h, ratio_w;
  cv::Mat img = ResizeWithinBounds(original, ratio_h, ratio_w);

  std::vector<Detected> dets = impl_->Detect(img);
  if (dets.empty()) return {};

  std::vector<cv::Mat> crops;
  crops.reserve(dets.size());
  for (const auto& d : dets) crops.push_back(CropQuad(img, d.quad));
  auto texts = impl_->Recognize(crops);

  std::vector<OcrLine> lines;
  for (size_t i = 0; i < dets.size(); ++i) {
    std::string t = texts[i].first;
    auto b = t.find_first_not_of(" \t\r\n");
    if (b == std::string::npos || texts[i].second < kTextScore) continue;
    OcrLine l;
    l.text = t.substr(b, t.find_last_not_of(" \t\r\n") - b + 1);
    l.score = texts[i].second;
    float x0 = 1e9f, y0 = 1e9f, x1 = 0, y1 = 0;
    for (const auto& p : dets[i].quad) {
      x0 = std::min(x0, p.x); y0 = std::min(y0, p.y);
      x1 = std::max(x1, p.x); y1 = std::max(y1, p.y);
    }
    l.box[0] = static_cast<float>(x0 * ratio_w); l.box[1] = static_cast<float>(y0 * ratio_h);
    l.box[2] = static_cast<float>(x1 * ratio_w); l.box[3] = static_cast<float>(y1 * ratio_h);
    lines.push_back(std::move(l));
  }
  cv::Mat gray;
  cv::cvtColor(original, gray, cv::COLOR_BGR2GRAY);
  for (auto& l : lines) l.bullet = HasBulletMark(gray, l.box);

  // Same final ordering as the Python server: by top, then left.
  std::stable_sort(lines.begin(), lines.end(), [](const OcrLine& a, const OcrLine& b) {
    return a.box[1] != b.box[1] ? a.box[1] < b.box[1] : a.box[0] < b.box[0];
  });
  return lines;
}

}  // namespace lingosnap
