# LingoSnap

Công cụ Windows chụp một vùng màn hình, nhận diện chữ bằng RapidOCR/ONNX Runtime và dịch
English → Vietnamese bằng Argos/CTranslate2 và kiểm tra ngữ pháp tiếng Anh bằng
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

Thiết lập backend và tải model lần đầu:

Yêu cầu Python 3.11 và Java 17:

```powershell
powershell -ExecutionPolicy Bypass -File backend\setup_backend.ps1
```

Sau đó Flutter sẽ tự mở và đóng Python backend khi cần.

## Đóng gói portable cho máy khác

Chạy trên máy build có Internet:

```powershell
powershell -ExecutionPolicy Bypass -File tool\build_portable.ps1
```

Script build ứng dụng Windows, tải Python Embedded, đóng gói Java runtime đang cài
trên máy build, cài toàn bộ dependency backend và tạo
`build\portable\LingoSnap-windows-x64.zip`. Có thể truyền `-JavaHome` nếu Java 17
không nằm trong `JAVA_HOME` hoặc `PATH`. Trên máy khác chỉ cần giải nén toàn bộ ZIP
rồi chạy `LingoSnap\capture_translate_tool.exe`; không cần Git, Flutter, Python,
Java hay Internet.

> Gói `screen_capturer` trên Windows yêu cầu Visual Studio workload Desktop
> development with C++ và ATL.
