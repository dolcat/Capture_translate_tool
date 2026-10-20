#include "live.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cctype>
#include <condition_variable>
#include <cstdlib>
#include <deque>
#include <future>
#include <mutex>
#include <stdexcept>
#include <opencv2/imgproc.hpp>
#include <thread>
#include <unordered_map>

#include "layout.h"

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

using nlohmann::json;
using Clock = std::chrono::steady_clock;

namespace lingosnap {
namespace {

// ---------------------------------------------------------------- text helpers

bool IsAlnumByte(unsigned char c) { return std::isalnum(c) != 0 || c >= 0x80; }

// Lower-cased letters and digits only, so OCR noise in punctuation/spacing does not count.
std::string NormalizeKey(const std::string& s) {
  std::string out;
  for (unsigned char c : s) {
    if (c >= 0x80) out.push_back(static_cast<char>(c));
    else if (std::isalnum(c)) out.push_back(static_cast<char>(std::tolower(c)));
  }
  return out;
}

size_t EditDistance(const std::string& a, const std::string& b) {
  std::vector<size_t> prev(b.size() + 1), cur(b.size() + 1);
  for (size_t j = 0; j <= b.size(); ++j) prev[j] = j;
  for (size_t i = 1; i <= a.size(); ++i) {
    cur[0] = i;
    for (size_t j = 1; j <= b.size(); ++j)
      cur[j] = std::min({prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)});
    std::swap(prev, cur);
  }
  return prev[b.size()];
}

// OCR can flip a character or two between frames; treat nearly equal texts as the same.
bool SameText(const std::string& a, const std::string& b) {
  if (a.empty() || b.empty()) return a == b;
  size_t longest = std::max(a.size(), b.size());
  size_t diff = a.size() > b.size() ? a.size() - b.size() : b.size() - a.size();
  if (diff > std::max<size_t>(2, longest * 15 / 100)) return false;
  return EditDistance(a, b) <= std::max<size_t>(1, longest / 10);
}

char Lower(char c) { return static_cast<char>(std::tolower(static_cast<unsigned char>(c))); }

// Case-insensitive (ASCII) match of `from` at text[i]; whole-word when it starts/ends with a word char.
bool MatchAt(const std::string& text, size_t i, const std::string& from) {
  if (from.empty() || i + from.size() > text.size()) return false;
  for (size_t k = 0; k < from.size(); ++k)
    if (Lower(text[i + k]) != Lower(from[k])) return false;
  if (IsAlnumByte(static_cast<unsigned char>(from.front())) && i > 0 &&
      IsAlnumByte(static_cast<unsigned char>(text[i - 1])))
    return false;
  if (IsAlnumByte(static_cast<unsigned char>(from.back())) && i + from.size() < text.size() &&
      IsAlnumByte(static_cast<unsigned char>(text[i + from.size()])))
    return false;
  return true;
}

std::string ReplaceTerm(const std::string& text, const std::string& from, const std::string& to) {
  if (from.empty()) return text;
  std::string out;
  size_t i = 0;
  while (i < text.size()) {
    if (MatchAt(text, i, from)) { out += to; i += from.size(); }
    else out.push_back(text[i++]);
  }
  return out;
}

std::string ApplyReplacements(std::string text, const std::vector<Replacement>& list) {
  for (const auto& r : list) text = ReplaceTerm(text, r.from, r.to);
  return text;
}

// Glossary terms must survive translation untouched, but the model mangles unknown names
// ("Zorvex" -> "Zovex"). So each match is swapped for a placeholder like "Qx1z", which the
// model copies verbatim, and the wanted text is put back afterwards.
std::string ProtectTerms(const std::string& text, std::vector<Replacement> terms,
                         std::vector<std::string>& values) {
  std::stable_sort(terms.begin(), terms.end(),
                   [](const Replacement& a, const Replacement& b) { return a.from.size() > b.from.size(); });
  std::string out;
  size_t i = 0;
  while (i < text.size()) {
    bool matched = false;
    for (const auto& t : terms) {
      if (!MatchAt(text, i, t.from)) continue;
      values.push_back(t.to.empty() ? text.substr(i, t.from.size()) : t.to);  // empty "to" = keep as is
      out += "Qx" + std::to_string(values.size()) + "z";
      i += t.from.size();
      matched = true;
      break;
    }
    if (!matched) out.push_back(text[i++]);
  }
  return out;
}

// Returns false when the model dropped or changed a placeholder.
bool RestoreTerms(std::string& text, const std::vector<std::string>& values) {
  bool all = true;
  for (size_t n = 0; n < values.size(); ++n) {
    std::string ph = "Qx" + std::to_string(n + 1) + "z";
    bool found = false;
    for (size_t i = 0; i + ph.size() <= text.size();) {
      bool eq = true;
      for (size_t k = 0; k < ph.size() && eq; ++k) eq = Lower(text[i + k]) == Lower(ph[k]);
      if (eq) { text.replace(i, ph.size(), values[n]); i += values[n].size(); found = true; }
      else ++i;
    }
    all = all && found;
  }
  return all;
}

// One subtitle = the recognized lines joined; lists/dialogue dashes keep their own lines.
std::string SubtitleText(const std::vector<OcrLine>& lines) {
  auto paragraphs = BuildParagraphs(lines);
  bool list_like = false;
  for (const auto& p : paragraphs) if (!ListMarker(p).empty()) list_like = true;
  std::string out;
  for (const auto& p : paragraphs) {
    if (!out.empty()) out += list_like ? "\n" : " ";
    out += p;
  }
  return out;
}

int Clamp(int v, int lo, int hi) { return std::max(lo, std::min(hi, v)); }

int64_t NowMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch()).count();
}

std::vector<Replacement> ParseReplacements(const json& j) {
  std::vector<Replacement> out;
  if (!j.is_array()) return out;
  for (const auto& item : j) {
    if (!item.is_object()) continue;
    std::string from = item.value("from", ""), to = item.value("to", "");
    size_t b = from.find_first_not_of(" \t");
    if (b == std::string::npos) continue;
    from = from.substr(b, from.find_last_not_of(" \t") - b + 1);
    out.push_back({from, to});
  }
  return out;
}

LiveConfig ParseConfig(const json& j, LiveConfig c) {
  if (!j.is_object()) return c;
  if (j.contains("region") && j["region"].is_object()) {
    const auto& r = j["region"];
    c.region.x = r.value("x", c.region.x);
    c.region.y = r.value("y", c.region.y);
    c.region.w = r.value("width", c.region.w);
    c.region.h = r.value("height", c.region.h);
  }
  c.interval_ms = Clamp(j.value("intervalMs", c.interval_ms), 100, 3000);
  c.stable_ms = Clamp(j.value("stableMs", c.stable_ms), 0, 3000);
  c.clear_delay_ms = Clamp(j.value("clearDelayMs", c.clear_delay_ms), 0, 10000);
  c.beam_size = Clamp(j.value("beamSize", c.beam_size), 1, 6);
  if (j.contains("pre")) c.pre = ParseReplacements(j["pre"]);
  if (j.contains("post")) c.post = ParseReplacements(j["post"]);
  if (j.contains("overlay") && j["overlay"].is_object()) {
    const auto& o = j["overlay"];
    c.overlay_enabled = o.value("enabled", c.overlay_enabled);
    std::string pos = o.value("position", c.overlay_position);
    if (pos == "cover" || pos == "below" || pos == "above") c.overlay_position = pos;
    c.font_size = Clamp(o.value("fontSize", c.font_size), 12, 96);
    c.opacity = Clamp(o.value("opacity", c.opacity), 30, 100);
    c.show_original = o.value("showOriginal", c.show_original);
    c.exclude_from_capture = o.value("excludeFromCapture", c.exclude_from_capture);
  }
  return c;
}

json ConfigJson(const LiveConfig& c) {
  auto list = [](const std::vector<Replacement>& v) {
    json a = json::array();
    for (const auto& r : v) a.push_back({{"from", r.from}, {"to", r.to}});
    return a;
  };
  return {{"region", {{"x", c.region.x}, {"y", c.region.y}, {"width", c.region.w}, {"height", c.region.h}}},
          {"intervalMs", c.interval_ms}, {"stableMs", c.stable_ms}, {"clearDelayMs", c.clear_delay_ms},
          {"beamSize", c.beam_size}, {"pre", list(c.pre)}, {"post", list(c.post)},
          {"overlay", {{"enabled", c.overlay_enabled}, {"position", c.overlay_position},
                       {"fontSize", c.font_size}, {"opacity", c.opacity},
                       {"showOriginal", c.show_original}, {"excludeFromCapture", c.exclude_from_capture}}}};
}

// ------------------------------------------------------------ platform layer

struct OverlayState {
  std::string translated, original;
  LiveConfig config;
};

#ifdef _WIN32

std::wstring Widen(const std::string& s) {
  if (s.empty()) return L"";
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
  return w;
}

bool CaptureRegion(const LiveRegion& r, cv::Mat& bgr) {
  if (r.w <= 0 || r.h <= 0) return false;
  HDC screen = GetDC(nullptr);
  if (!screen) return false;
  HDC mem = CreateCompatibleDC(screen);
  BITMAPINFO bi{};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = r.w;
  bi.bmiHeader.biHeight = -r.h;  // top-down
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HBITMAP bmp = CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  bool ok = false;
  if (bmp && bits) {
    HGDIOBJ old = SelectObject(mem, bmp);
    ok = BitBlt(mem, 0, 0, r.w, r.h, screen, r.x, r.y, SRCCOPY | CAPTUREBLT) != FALSE;
    if (ok) {
      cv::Mat bgra(r.h, r.w, CV_8UC4, bits);
      cv::cvtColor(bgra, bgr, cv::COLOR_BGRA2BGR);
    }
    SelectObject(mem, old);
  }
  if (bmp) DeleteObject(bmp);
  DeleteDC(mem);
  ReleaseDC(nullptr, screen);
  return ok;
}

// All windows live on one dedicated thread with its own message loop.
class Ui {
 public:
  static Ui& Get() { static Ui ui; return ui; }

  void ShowOverlay(const OverlayState& s) {
    Ensure();
    { std::lock_guard<std::mutex> l(mutex_); pending_overlay_ = s; has_overlay_ = true; }
    PostThreadMessageW(thread_id_, kShow, 0, 0);
  }

  void HideOverlay() {
    if (!thread_id_) return;
    { std::lock_guard<std::mutex> l(mutex_); has_overlay_ = false; }
    PostThreadMessageW(thread_id_, kHide, 0, 0);
  }

  // Returns false on cancel/timeout.
  bool Select(LiveRegion& out) {
    Ensure();
    auto pending = std::make_shared<Pending>();
    { std::lock_guard<std::mutex> l(mutex_); select_ = pending; }
    PostThreadMessageW(thread_id_, kSelect, 0, 0);
    std::unique_lock<std::mutex> lock(pending->m);
    pending->cv.wait_for(lock, std::chrono::seconds(120), [&] { return pending->done; });
    if (!pending->done) { pending->abandoned = true; return false; }
    if (pending->cancelled) return false;
    out = pending->region;
    return true;
  }

 private:
  static constexpr UINT kShow = WM_APP + 1, kHide = WM_APP + 2, kSelect = WM_APP + 3;

  struct Pending {
    std::mutex m;
    std::condition_variable cv;
    bool done = false, cancelled = false, abandoned = false;
    LiveRegion region;
  };

  void Ensure() {
    std::call_once(once_, [this] {
      auto ready = std::make_shared<std::promise<void>>();
      auto fut = ready->get_future();
      thread_ = std::thread([this, ready] { Run(*ready); });
      thread_.detach();
      fut.wait();
    });
  }

  void Run(std::promise<void>& ready) {
    thread_id_ = GetCurrentThreadId();
    MSG msg;
    PeekMessageW(&msg, nullptr, WM_USER, WM_USER, PM_NOREMOVE);  // creates the queue
    HINSTANCE inst = GetModuleHandleW(nullptr);
    WNDCLASSW oc{};
    oc.lpfnWndProc = &Ui::OverlayProc;
    oc.hInstance = inst;
    oc.lpszClassName = L"LingoSnapOverlay";
    oc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    RegisterClassW(&oc);
    WNDCLASSW sc{};
    sc.lpfnWndProc = &Ui::SelectorProc;
    sc.hInstance = inst;
    sc.lpszClassName = L"LingoSnapSelector";
    RegisterClassW(&sc);
    ready.set_value();

    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
      if (msg.hwnd == nullptr) {
        if (msg.message == kShow) { ApplyOverlay(); continue; }
        if (msg.message == kHide) { if (overlay_) ShowWindow(overlay_, SW_HIDE); continue; }
        if (msg.message == kSelect) { BeginSelect(); continue; }
      }
      TranslateMessage(&msg);
      DispatchMessageW(&msg);
    }
  }

  // ----- overlay

  void ApplyOverlay() {
    OverlayState s;
    { std::lock_guard<std::mutex> l(mutex_); if (!has_overlay_) return; s = pending_overlay_; }
    const LiveConfig& c = s.config;
    if (!overlay_) {
      overlay_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED |
                                     WS_EX_TRANSPARENT,
                                 L"LingoSnapOverlay", L"LingoSnap subtitles", WS_POPUP, 0, 0, 10, 10,
                                 nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
      if (!overlay_) return;
    }
    SetWindowDisplayAffinity(overlay_, c.exclude_from_capture ? 0x11 /*WDA_EXCLUDEFROMCAPTURE*/ : 0);

    translated_ = Widen(s.translated);
    original_ = c.show_original ? Widen(s.original) : L"";
    if (main_font_) DeleteObject(main_font_);
    if (small_font_) DeleteObject(small_font_);
    auto make_font = [](int px, int weight) {
      return CreateFontW(-px, 0, 0, 0, weight, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                         CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
    };
    int small_px = std::max(12, c.font_size * 6 / 10);
    main_font_ = make_font(c.font_size, FW_SEMIBOLD);
    small_font_ = make_font(small_px, FW_NORMAL);
    pad_ = c.font_size / 2 + 6;

    const LiveRegion& r = c.region;
    POINT center{r.x + r.w / 2, r.y + r.h / 2};
    MONITORINFO mi{sizeof(mi)};
    GetMonitorInfoW(MonitorFromPoint(center, MONITOR_DEFAULTTONEAREST), &mi);
    const RECT mon = mi.rcMonitor;

    int width = std::min<int>(std::max(r.w, 480), mon.right - mon.left - 16);
    HDC dc = GetDC(overlay_);
    auto measure = [&](const std::wstring& text, HFONT font) {
      if (text.empty()) return 0;
      HGDIOBJ old = SelectObject(dc, font);
      RECT rc{0, 0, width - 2 * pad_, 0};
      DrawTextW(dc, text.c_str(), -1, &rc, DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX | DT_CENTER);
      SelectObject(dc, old);
      return static_cast<int>(rc.bottom - rc.top);
    };
    main_h_ = measure(translated_, main_font_);
    small_h_ = measure(original_, small_font_);
    ReleaseDC(overlay_, dc);
    gap_ = small_h_ > 0 ? 6 : 0;
    int height = main_h_ + gap_ + small_h_ + 2 * pad_;

    int x = r.x + (r.w - width) / 2;
    int y;
    if (c.overlay_position == "below") y = r.y + r.h + 6;
    else if (c.overlay_position == "above") y = r.y - height - 6;
    else { height = std::max(height, r.h); y = r.y + r.h - height; }  // cover: bottom-aligned
    if (c.overlay_position == "below" && y + height > mon.bottom - 4) y = r.y - height - 6;
    if (c.overlay_position == "above" && y < mon.top + 4) y = r.y + r.h + 6;
    x = Clamp(x, mon.left + 8, std::max<int>(mon.left + 8, mon.right - 8 - width));
    y = Clamp(y, mon.top + 4, std::max<int>(mon.top + 4, mon.bottom - 4 - height));
    width_ = width;
    height_ = height;

    SetLayeredWindowAttributes(overlay_, 0, static_cast<BYTE>(255 * c.opacity / 100), LWA_ALPHA);
    SetWindowPos(overlay_, HWND_TOPMOST, x, y, width, height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    SetWindowRgn(overlay_, CreateRoundRectRgn(0, 0, width + 1, height + 1, 16, 16), TRUE);
    InvalidateRect(overlay_, nullptr, TRUE);
    UpdateWindow(overlay_);
    // Windows only honours the exclusion reliably once the window is on screen.
    SetWindowDisplayAffinity(overlay_, c.exclude_from_capture ? 0x11 /*WDA_EXCLUDEFROMCAPTURE*/ : 0);
  }

  static LRESULT CALLBACK OverlayProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    Ui& ui = Get();
    switch (msg) {
      case WM_ERASEBKGND: return 1;
      case WM_NCHITTEST: return HTTRANSPARENT;
      case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
      case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(hwnd, &ps);
        ui.PaintOverlay(dc);
        EndPaint(hwnd, &ps);
        return 0;
      }
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
  }

  void PaintOverlay(HDC dc) {
    HBRUSH bg = CreateSolidBrush(RGB(12, 12, 14));
    RECT all{0, 0, width_, height_};
    FillRect(dc, &all, bg);
    DeleteObject(bg);
    SetBkMode(dc, TRANSPARENT);
    int content = main_h_ + gap_ + small_h_;
    int top = std::max(pad_, (height_ - content) / 2);
    RECT main_rc{pad_, top, width_ - pad_, top + main_h_};
    HGDIOBJ old = SelectObject(dc, main_font_);
    SetTextColor(dc, RGB(255, 255, 255));
    DrawTextW(dc, translated_.c_str(), -1, &main_rc, DT_WORDBREAK | DT_NOPREFIX | DT_CENTER);
    if (small_h_ > 0) {
      RECT small_rc{pad_, top + main_h_ + gap_, width_ - pad_, top + main_h_ + gap_ + small_h_};
      SelectObject(dc, small_font_);
      SetTextColor(dc, RGB(170, 175, 185));
      DrawTextW(dc, original_.c_str(), -1, &small_rc, DT_WORDBREAK | DT_NOPREFIX | DT_CENTER);
    }
    SelectObject(dc, old);
  }

  // ----- region selector

  void BeginSelect() {
    std::shared_ptr<Pending> pending;
    { std::lock_guard<std::mutex> l(mutex_); pending = select_; }
    if (!pending) return;
    if (selector_) { FinishSelect(true); }
    active_ = pending;
    sel_origin_ = POINT{GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN)};
    int w = GetSystemMetrics(SM_CXVIRTUALSCREEN), h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    dragging_ = false;
    selector_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED, L"LingoSnapSelector",
                                L"LingoSnap region", WS_POPUP, sel_origin_.x, sel_origin_.y, w, h, nullptr,
                                nullptr, GetModuleHandleW(nullptr), nullptr);
    if (!selector_) { FinishSelect(true); return; }
    SetWindowDisplayAffinity(selector_, 0x11);
    SetLayeredWindowAttributes(selector_, 0, 110, LWA_ALPHA);
    ShowWindow(selector_, SW_SHOWNOACTIVATE);
    SetTimer(selector_, 1, 40, nullptr);  // Esc polling: the window may not have keyboard focus
    InvalidateRect(selector_, nullptr, TRUE);
  }

  void FinishSelect(bool cancelled) {
    if (selector_) {
      HWND w = selector_;
      selector_ = nullptr;
      KillTimer(w, 1);
      DestroyWindow(w);
    }
    auto pending = active_;
    active_.reset();
    if (!pending) return;
    std::lock_guard<std::mutex> l(pending->m);
    pending->done = true;
    pending->cancelled = cancelled;
    if (!cancelled) {
      pending->region = LiveRegion{std::min(sel_a_.x, sel_b_.x) + sel_origin_.x,
                                   std::min(sel_a_.y, sel_b_.y) + sel_origin_.y,
                                   std::abs(sel_b_.x - sel_a_.x), std::abs(sel_b_.y - sel_a_.y)};
    }
    pending->cv.notify_all();
  }

  void PaintSelector(HWND hwnd, HDC target) {
    RECT client;
    GetClientRect(hwnd, &client);
    HDC mem = CreateCompatibleDC(target);
    HBITMAP bmp = CreateCompatibleBitmap(target, client.right, client.bottom);
    HGDIOBJ old = SelectObject(mem, bmp);
    HBRUSH dark = CreateSolidBrush(RGB(0, 0, 0));
    FillRect(mem, &client, dark);
    DeleteObject(dark);
    SetBkMode(mem, TRANSPARENT);
    if (dragging_) {
      RECT r{std::min(sel_a_.x, sel_b_.x), std::min(sel_a_.y, sel_b_.y), std::max(sel_a_.x, sel_b_.x),
             std::max(sel_a_.y, sel_b_.y)};
      HBRUSH fill = CreateSolidBrush(RGB(70, 140, 255));
      FillRect(mem, &r, fill);
      DeleteObject(fill);
      HBRUSH border = CreateSolidBrush(RGB(255, 255, 255));
      FrameRect(mem, &r, border);
      DeleteObject(border);
      std::wstring label = std::to_wstring(r.right - r.left) + L" × " + std::to_wstring(r.bottom - r.top);
      SetTextColor(mem, RGB(255, 255, 255));
      TextOutW(mem, r.left + 6, std::max<LONG>(0, r.top - 22), label.c_str(), static_cast<int>(label.size()));
    } else {
      HFONT font = CreateFontW(-26, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                               OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
                               DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
      HGDIOBJ oldf = SelectObject(mem, font);
      SetTextColor(mem, RGB(255, 255, 255));
      std::wstring hint = L"Kéo chuột để chọn vùng phụ đề  •  Esc hoặc chuột phải để hủy";
      RECT rc{0, 80, client.right, 140};
      DrawTextW(mem, hint.c_str(), -1, &rc, DT_CENTER | DT_NOPREFIX);
      SelectObject(mem, oldf);
      DeleteObject(font);
    }
    BitBlt(target, 0, 0, client.right, client.bottom, mem, 0, 0, SRCCOPY);
    SelectObject(mem, old);
    DeleteObject(bmp);
    DeleteDC(mem);
  }

  static LRESULT CALLBACK SelectorProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    Ui& ui = Get();
    auto pt = [&] { return POINT{static_cast<short>(LOWORD(lp)), static_cast<short>(HIWORD(lp))}; };
    switch (msg) {
      case WM_ERASEBKGND: return 1;
      case WM_SETCURSOR: SetCursor(LoadCursor(nullptr, IDC_CROSS)); return TRUE;
      case WM_LBUTTONDOWN:
        SetCapture(hwnd);
        ui.dragging_ = true;
        ui.sel_a_ = ui.sel_b_ = pt();
        InvalidateRect(hwnd, nullptr, FALSE);
        return 0;
      case WM_MOUSEMOVE:
        if (ui.dragging_) { ui.sel_b_ = pt(); InvalidateRect(hwnd, nullptr, FALSE); }
        return 0;
      case WM_LBUTTONUP:
        if (ui.dragging_) {
          ReleaseCapture();
          ui.sel_b_ = pt();
          ui.dragging_ = false;
          bool tiny = std::abs(ui.sel_b_.x - ui.sel_a_.x) < 16 || std::abs(ui.sel_b_.y - ui.sel_a_.y) < 12;
          if (tiny) { InvalidateRect(hwnd, nullptr, FALSE); return 0; }  // ignore stray clicks
          ui.FinishSelect(false);
        }
        return 0;
      case WM_RBUTTONDOWN: ui.FinishSelect(true); return 0;
      case WM_TIMER:
        if (GetAsyncKeyState(VK_ESCAPE) & 0x8000) ui.FinishSelect(true);
        return 0;
      case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(hwnd, &ps);
        ui.PaintSelector(hwnd, dc);
        EndPaint(hwnd, &ps);
        return 0;
      }
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
  }

  std::once_flag once_;
  std::thread thread_;
  DWORD thread_id_ = 0;
  std::mutex mutex_;
  OverlayState pending_overlay_;
  bool has_overlay_ = false;
  std::shared_ptr<Pending> select_;

  // UI-thread only
  HWND overlay_ = nullptr, selector_ = nullptr;
  HFONT main_font_ = nullptr, small_font_ = nullptr;
  std::wstring translated_, original_;
  int pad_ = 14, main_h_ = 0, small_h_ = 0, gap_ = 0, width_ = 0, height_ = 0;
  std::shared_ptr<Pending> active_;
  POINT sel_origin_{0, 0}, sel_a_{0, 0}, sel_b_{0, 0};
  bool dragging_ = false;
};

#else  // non-Windows: the live feature needs the Windows screen APIs

bool CaptureRegion(const LiveRegion&, cv::Mat&) { return false; }
class Ui {
 public:
  static Ui& Get() { static Ui ui; return ui; }
  void ShowOverlay(const OverlayState&) {}
  void HideOverlay() {}
  bool Select(LiveRegion&) { return false; }
};

#endif

}  // namespace

// ------------------------------------------------------------------ the engine

struct LiveEntry {
  int seq;
  std::string original, translated;
  int64_t time_ms;
};

struct LiveTranslator::Impl {
  OcrFn ocr;
  TranslateFn translate;

  mutable std::mutex mutex;
  std::condition_variable wake;
  LiveConfig config;
  uint64_t version = 0;
  bool running = false;
  std::thread worker;

  int seq = 0;
  std::string last_original, last_translated, error;
  int ocr_ms = 0, translate_ms = 0;
  int64_t updated_ms = 0;
  std::deque<LiveEntry> history;

  Impl(OcrFn o, TranslateFn t) : ocr(std::move(o)), translate(std::move(t)) {}

  void StopWorker() {
    {
      std::lock_guard<std::mutex> l(mutex);
      running = false;
    }
    wake.notify_all();
    if (worker.joinable()) worker.join();
    Ui::Get().HideOverlay();
  }

  bool Sleep(int ms) {  // false when stopped
    std::unique_lock<std::mutex> l(mutex);
    wake.wait_for(l, std::chrono::milliseconds(std::max(ms, 1)), [&] { return !running; });
    return running;
  }

  void SetError(const std::string& e) {
    std::lock_guard<std::mutex> l(mutex);
    error = e;
  }

  std::string Translate(const std::string& text, const LiveConfig& cfg,
                        std::unordered_map<std::string, std::string>& cache) {
    auto hit = cache.find(text);
    if (hit != cache.end()) return hit->second;
    auto t0 = Clock::now();
    std::vector<std::string> values;
    std::string out = translate(ProtectTerms(text, cfg.pre, values), cfg.beam_size);
    if (!RestoreTerms(out, values)) {
      // The model lost a placeholder: translate again with the wanted words written in directly.
      std::vector<Replacement> direct = cfg.pre;
      for (auto& r : direct) if (r.to.empty()) r.to = r.from;
      out = translate(ApplyReplacements(text, direct), cfg.beam_size);
    }
    out = ApplyReplacements(out, cfg.post);
    int ms = static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - t0).count());
    { std::lock_guard<std::mutex> l(mutex); translate_ms = ms; }
    if (cache.size() > 500) cache.clear();
    cache[text] = out;
    return out;
  }

  void Publish(const std::string& original, const std::string& translated, const LiveConfig& cfg,
               bool new_entry) {
    {
      std::lock_guard<std::mutex> l(mutex);
      last_original = original;
      last_translated = translated;
      updated_ms = NowMs();
      if (new_entry) {
        history.push_back({++seq, original, translated, updated_ms});
        if (history.size() > 200) history.pop_front();
      }
    }
    if (cfg.overlay_enabled) Ui::Get().ShowOverlay({translated, original, cfg});
    else Ui::Get().HideOverlay();
  }

  void Loop() {
    cv::Mat prev_gray;
    std::string frame_text;  // result of the last OCR run
    std::string cand_key, cand_text;
    int cand_count = 0;
    Clock::time_point cand_since = Clock::now();
    std::string shown_key, shown_original, shown_translated;
    uint64_t seen_version = ~0ull;
    std::unordered_map<std::string, std::string> cache;
    Clock::time_point overlay_changed = Clock::now() - std::chrono::seconds(10);

    while (true) {
      LiveConfig cfg;
      uint64_t ver;
      {
        std::lock_guard<std::mutex> l(mutex);
        if (!running) return;
        cfg = config;
        ver = version;
      }
      auto started = Clock::now();

      try {
        if (ver != seen_version) {
          bool first = seen_version == ~0ull;
          seen_version = ver;
          prev_gray.release();
          cache.clear();
          if (!first && !shown_original.empty()) {  // settings changed: redo with the new glossary/style
            shown_translated = Translate(shown_original, cfg, cache);
            Publish(shown_original, shown_translated, cfg, false);
            overlay_changed = Clock::now();
          }
        }

        // Right after the overlay moves, the compositor may still show it in our capture.
        if (Clock::now() - overlay_changed < std::chrono::milliseconds(350)) {
          if (!Sleep(60)) return;
          continue;
        }
        cv::Mat frame;
        if (!CaptureRegion(cfg.region, frame)) throw std::runtime_error("Không chụp được vùng màn hình đã chọn.");
        cv::Mat gray;
        cv::cvtColor(frame, gray, cv::COLOR_BGR2GRAY);

        bool same = false;
        if (!prev_gray.empty() && prev_gray.size() == gray.size()) {
          cv::Mat diff, mask;
          cv::absdiff(gray, prev_gray, diff);
          cv::threshold(diff, mask, 30, 255, cv::THRESH_BINARY);
          same = cv::countNonZero(mask) < std::max<double>(25, gray.total() * 0.0004);
        }
        if (!same) {
          auto t0 = Clock::now();
          if (!frame.isContinuous()) frame = frame.clone();
          frame_text = SubtitleText(ocr(frame.data, frame.cols, frame.rows, static_cast<int>(frame.step)));
          int ms = static_cast<int>(
              std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - t0).count());
          prev_gray = gray;
          std::lock_guard<std::mutex> l(mutex);
          ocr_ms = ms;
          error.clear();
        }

        std::string key = NormalizeKey(frame_text);
        if (key.size() < 2) key.clear();  // stray marks, not a subtitle
        // If the capture still contains our own overlay, that text is the translation, not a new subtitle.
        if (!key.empty() && !shown_translated.empty() && SameText(key, NormalizeKey(shown_translated)))
          key = shown_key;
        auto now = Clock::now();
        if (key.empty() ? !cand_key.empty() || cand_count == 0 : !SameText(key, cand_key)) {
          cand_key = key;
          cand_text = key.empty() ? "" : frame_text;
          cand_count = 1;
          cand_since = now;
        } else {
          ++cand_count;
        }
        auto held = std::chrono::duration_cast<std::chrono::milliseconds>(now - cand_since).count();

        if (cand_key.empty()) {
          if (!shown_key.empty() && held >= cfg.clear_delay_ms) {
            shown_key.clear();
            shown_original.clear();
            shown_translated.clear();
            Ui::Get().HideOverlay();
            overlay_changed = Clock::now();
          }
        } else if (cand_count >= 2 && held >= cfg.stable_ms && !SameText(cand_key, shown_key)) {
          shown_key = cand_key;
          shown_original = cand_text;
          shown_translated = Translate(shown_original, cfg, cache);
          Publish(shown_original, shown_translated, cfg, true);
          overlay_changed = Clock::now();
        }
      } catch (const std::exception& e) {
        SetError(e.what());
        if (!Sleep(1000)) return;
      }

      auto spent = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - started).count();
      if (!Sleep(static_cast<int>(cfg.interval_ms - spent))) return;
    }
  }
};

LiveTranslator::LiveTranslator(OcrFn ocr, TranslateFn translate)
    : impl_(std::make_unique<Impl>(std::move(ocr), std::move(translate))) {}

LiveTranslator::~LiveTranslator() { impl_->StopWorker(); }

bool LiveTranslator::Start(const json& config, std::string& error) {
#ifndef _WIN32
  error = "Dịch phụ đề trực tiếp hiện chỉ hỗ trợ Windows.";
  return false;
#endif
  impl_->StopWorker();
  LiveConfig cfg = ParseConfig(config, LiveConfig{});
  if (cfg.region.w < 16 || cfg.region.h < 12) {
    error = "Hãy chọn vùng phụ đề trước (tối thiểu 16×12 điểm ảnh).";
    return false;
  }
  {
    std::lock_guard<std::mutex> l(impl_->mutex);
    impl_->config = cfg;
    ++impl_->version;
    impl_->running = true;
    impl_->error.clear();
    impl_->last_original.clear();
    impl_->last_translated.clear();
  }
  impl_->worker = std::thread([this] { impl_->Loop(); });
  return true;
}

void LiveTranslator::Stop() { impl_->StopWorker(); }

bool LiveTranslator::Configure(const json& config, std::string& error) {
  std::lock_guard<std::mutex> l(impl_->mutex);
  LiveConfig cfg = ParseConfig(config, impl_->config);
  if (cfg.region.w < 16 || cfg.region.h < 12) {
    error = "Vùng phụ đề không hợp lệ.";
    return false;
  }
  impl_->config = cfg;
  ++impl_->version;
  return true;
}

bool LiveTranslator::SelectRegion(LiveRegion& out, std::string& error) {
#ifndef _WIN32
  error = "Chọn vùng màn hình hiện chỉ hỗ trợ Windows.";
  return false;
#endif
  error.clear();
  return Ui::Get().Select(out);
}

json LiveTranslator::Status() const {
  std::lock_guard<std::mutex> l(impl_->mutex);
  const auto& r = impl_->config.region;
  return {{"running", impl_->running},
          {"region", {{"x", r.x}, {"y", r.y}, {"width", r.w}, {"height", r.h}}},
          {"seq", impl_->seq},
          {"original", impl_->last_original},
          {"translated", impl_->last_translated},
          {"ocrMs", impl_->ocr_ms},
          {"translateMs", impl_->translate_ms},
          {"updatedAt", impl_->updated_ms},
          {"config", ConfigJson(impl_->config)},
          {"error", impl_->error.empty() ? json(nullptr) : json(impl_->error)}};
}

json LiveTranslator::History(int since_seq) const {
  std::lock_guard<std::mutex> l(impl_->mutex);
  json items = json::array();
  for (const auto& e : impl_->history)
    if (e.seq > since_seq)
      items.push_back({{"seq", e.seq}, {"original", e.original}, {"translated", e.translated}, {"time", e.time_ms}});
  return {{"items", items}, {"seq", impl_->seq}};
}

}  // namespace lingosnap
