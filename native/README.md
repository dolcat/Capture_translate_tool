# LingoSnap native backend

Thay thế `backend/server.py` (Python/FastAPI) bằng một file thực thi C++ duy nhất,
giữ nguyên giao diện HTTP để Flutter không phải đổi hợp đồng:

- `GET /health`, `POST /analyze`, `POST /translate`, `POST /grammar`, `POST /grammar/warmup`

| Phần | Cách làm |
|---|---|
| OCR | `src/ocr.cc`: PP-OCRv5 mobile (det + rec) chạy bằng ONNX Runtime; tiền xử lý, hậu xử lý DB, cắt dòng và giải mã CTC làm lại theo RapidOCR, dùng OpenCV (core/imgproc/imgcodecs) |
| Dịch | `src/translator.cc`: SentencePiece + API C++ của CTranslate2 (INT8, CPU, beam 2) |
| Ngữ pháp | `src/grammar.cc`: chạy LanguageTool (Java) làm tiến trình con, backend C++ gọi `/v2/check` và áp dụng gợi ý đầu tiên |
| Bố cục | `src/layout.cc`: dựng lại đoạn văn và gạch đầu dòng từ vị trí các dòng OCR |
| Phụ đề trực tiếp | `src/live.cc`: chụp một vùng màn hình (Windows), chỉ OCR khi ảnh đổi, chờ chữ đứng yên rồi dịch một lần, hiện bản dịch trong cửa sổ trong suốt luôn nằm trên cùng (ẩn khỏi ảnh chụp màn hình để không đọc lại chính nó) |
| Server | `src/main.cc`: cpp-httplib + nlohmann/json, nạp model OCR/dịch ở luồng nền ngay khi mở |

## Dịch phụ đề trực tiếp

- `POST /live/select-region`: người dùng kéo chuột chọn vùng, trả `{x,y,width,height}` (pixel vật lý) hoặc `{cancelled:true}`.
- `POST /live/start` / `POST /live/config`: nhận cùng một JSON cấu hình (khoá vắng mặt giữ giá trị mặc định/hiện tại):
  `region`, `intervalMs`, `stableMs`, `clearDelayMs`, `beamSize`, `pre`, `post`, `overlay{enabled,position,fontSize,opacity,showOriginal,excludeFromCapture}`.
- `POST /live/stop`, `GET /live/status`, `GET /live/history?since=<seq>`.

Cửa sổ dịch riêng: khoá `window{enabled,alwaysOnTop,rect}` mở một cửa sổ thường (kéo, đổi kích thước được,
chữ tự thu nhỏ cho vừa). `GET /live/status` trả `window.rect` (vị trí hiện tại) và `window.closed` (người dùng đã
bấm X). Cửa sổ ở trạng thái đóng cho tới khi `enabled` được tắt rồi bật lại.

Tuỳ chỉnh bản dịch: `pre` là danh sách `{from,to}` tên riêng/thuật ngữ. Mỗi lần khớp được thay bằng một
ký hiệu giữ chỗ (`Qx1z`) để máy dịch không làm hỏng tên, dịch xong mới thay lại bằng `to` (để trống = giữ
nguyên). `post` là danh sách `{from,to}` sửa thẳng bản dịch. `beamSize` 1–6 đổi tốc độ lấy chất lượng.

Gỡ lỗi nhanh: `lingosnap_backend --models <thư mục models> --ocr anh.png` in các dòng OCR.
Biến môi trường `LINGOSNAP_MODELS` đổi thư mục model, `LINGOSNAP_CHILD_LOG` ghi log của Java.

Build trên Windows: `tool\build_native.ps1`. Build trên Linux (để phát triển/test): xem
`CMakeLists.txt` (cần ONNX Runtime, CTranslate2, OpenCV và SentencePiece build sẵn).
