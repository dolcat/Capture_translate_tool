# LingoSnap native backend

Thay thế `backend/server.py` (Python/FastAPI) bằng một file thực thi C++ duy nhất,
giữ nguyên giao diện HTTP để Flutter không phải đổi hợp đồng:

- `GET /health`, `POST /analyze`, `POST /translate`, `POST /grammar`, `POST /grammar/warmup`

| Phần | Cách làm |
|---|---|
| OCR | `src/ocr.cc`: PP-OCRv5 mobile (det + rec) chạy bằng ONNX Runtime; tiền xử lý, hậu xử lý DB, cắt dòng và giải mã CTC làm lại theo RapidOCR, dùng OpenCV (core/imgproc/imgcodecs) |
| Dịch | `src/translator.cc`: SentencePiece + API C++ của CTranslate2 (INT8, CPU, beam 2) |
| Ngữ pháp | `src/grammar.cc`: chạy LanguageTool (Java) làm tiến trình con, backend C++ gọi `/v2/check` và áp dụng gợi ý đầu tiên |
| Server | `src/main.cc`: cpp-httplib + nlohmann/json, nạp model OCR/dịch ở luồng nền ngay khi mở |

Gỡ lỗi nhanh: `lingosnap_backend --models <thư mục models> --ocr anh.png` in các dòng OCR.
Biến môi trường `LINGOSNAP_MODELS` đổi thư mục model, `LINGOSNAP_CHILD_LOG` ghi log của Java.

Build trên Windows: `tool\build_native.ps1`. Build trên Linux (để phát triển/test): xem
`CMakeLists.txt` (cần ONNX Runtime, CTranslate2, OpenCV và SentencePiece build sẵn).
