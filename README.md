# LingoSnap

Công cụ Windows chụp một vùng màn hình, nhận diện chữ bằng PP-OCRv5 chạy trên ONNX Runtime (C++) và dịch
English → Vietnamese bằng Argos/CTranslate2 (C++) và kiểm tra ngữ pháp tiếng Anh bằng
LanguageTool, hoàn toàn offline.

## Chạy giao diện

```powershell
flutter pub get
flutter run -d windows
```

Ứng dụng gọi backend cục bộ qua `POST http://127.0.0.1:8765/analyze` theo hợp
đồng trong `docs/tom_tat_tool.md`. Các phím tắt mặc định là `Ctrl + Shift + T`
để chụp vùng màn hình, `Ctrl + N` để tạo bản dịch nhập tay mới và `Enter` để
dịch nội dung trong ô nguồn (`Shift + Enter` để xuống dòng). `Ctrl + Tab` chuyển
qua lại giữa chức năng Dịch và Ngữ pháp. Người dùng có thể chỉnh cả bốn tổ hợp
trong **Settings**; cấu hình được lưu tại
`%APPDATA%\LingoSnap\settings.json`.

Backend là chương trình C++ `lingosnap_backend.exe` (không còn Python). Thiết lập lần đầu
trên Windows (cần Visual Studio 2022 Desktop C++, CMake, Git, Java 17 cho LanguageTool):

```powershell
powershell -ExecutionPolicy Bypass -File tool\build_native.ps1   # build backend vào build\native\stage
powershell -ExecutionPolicy Bypass -File tool\setup_models.ps1   # tải model vào backend\models
```

Sau đó Flutter sẽ tự mở và đóng backend khi cần. Xem `native/README.md` để biết kiến trúc.

## Đóng gói portable cho máy khác

Chạy trên máy build có Internet:

```powershell
powershell -ExecutionPolicy Bypass -File tool\build_portable.ps1
```

Script build ứng dụng Windows, đóng gói Java runtime đang cài trên máy build
(chỉ dùng cho LanguageTool), copy backend C++ cùng model, chạy thử backend và tạo
`build\portable\LingoSnap-windows-x64.zip`. Có thể truyền `-JavaHome` nếu Java 17
không nằm trong `JAVA_HOME` hoặc `PATH`. Trên máy khác chỉ cần giải nén toàn bộ ZIP
rồi chạy `LingoSnap\capture_translate_tool.exe`; không cần Git, Flutter, Python,
Java hay Internet.

> Gói `screen_capturer` trên Windows yêu cầu Visual Studio workload Desktop
> development with C++ và ATL.
