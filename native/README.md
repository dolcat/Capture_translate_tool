# LingoSnap native backend

Thay thế `backend/server.py` (Python/FastAPI) bằng một file thực thi C++ duy nhất,
giữ nguyên giao diện HTTP để Flutter không phải đổi hợp đồng:

- `GET /health`, `POST /analyze`, `POST /translate`, `POST /grammar`, `POST /grammar/warmup`

| Phần | Cách làm |
|---|---|
| OCR | `src/ocr.cc`: PP-OCRv6 small (det + rec) chạy bằng ONNX Runtime; tiền xử lý, hậu xử lý DB, cắt dòng và giải mã CTC làm lại theo RapidOCR, dùng OpenCV (core/imgproc/imgcodecs) |
| Dịch | `src/translator.cc`: SentencePiece + API C++ của CTranslate2 (INT8, CPU, beam 2, 2 luồng). Dùng `models/vinai-en-vi` (VinAI Translate en2vi v2, mBART: nguồn `… </s> en_XX`, bắt đầu giải mã bằng `vi_VN`) nếu có, nếu không thì `models/argos-en-vi` (Marian) |
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
Biến môi trường `LINGOSNAP_MODELS` đổi thư mục model, `LINGOSNAP_CHILD_LOG` ghi log của Java,
`LINGOSNAP_MT_THREADS` số luồng CPU cho máy dịch (mặc định 2 để không tranh CPU với game; 0 = mọi nhân vật lý).
`POST /translate` nhận thêm `beamSize` (tuỳ chọn, mặc định 2); `GET /health` trả `translationModel` (model đang dùng).

Model VinAI: chạy `tool\convert_vinai.ps1` một lần (cần Python cho riêng bước chuyển đổi; giấy phép
AGPL-3.0). Script kiểm tra một câu mẫu và chỉ thay model cũ khi bản dịch không bị lặp.

Build trên Windows: `tool\build_native.ps1`. Script build CTranslate2 4.8.3 từ nguồn chỉ để lấy header và
import library, còn `ctranslate2.dll` + `libiomp5md.dll` lúc chạy lấy từ wheel PyPI cùng phiên bản (có kiểm
SHA256): bản đó dùng Intel MKL nên INT8 nhanh hơn khoảng 5 lần bản Ruy, đổi lại backend nặng thêm khoảng 54 MB
(MKL và OpenMP runtime của Intel được phép tái phân phối). Build trên Linux (để phát triển/test): xem
`CMakeLists.txt` (cần ONNX Runtime, CTranslate2, OpenCV và SentencePiece build sẵn).
