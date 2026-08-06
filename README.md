# LingoSnap

Công cụ Windows chụp một vùng màn hình, nhận diện chữ bằng RapidOCR/ONNX Runtime và dịch
English → Vietnamese bằng Argos/CTranslate2 hoàn toàn offline.

## Chạy giao diện

```powershell
flutter pub get
flutter run -d windows
```

Ứng dụng gọi backend cục bộ qua `POST http://127.0.0.1:8765/analyze` theo hợp
đồng trong `docs/tom_tat_tool.md`. Phím tắt toàn hệ thống mặc định là
`Ctrl + Shift + T`. Người dùng có thể ghi và lưu một tổ hợp khác trong
**Settings → Phím tắt chụp vùng**; cấu hình được lưu tại
`%APPDATA%\LingoSnap\settings.json`.

Thiết lập backend và tải model lần đầu:

```powershell
powershell -ExecutionPolicy Bypass -File backend\setup_backend.ps1
```

Sau đó Flutter sẽ tự mở và đóng Python backend khi cần.

## Đóng gói portable cho máy khác

Chạy trên máy build có Internet:

```powershell
powershell -ExecutionPolicy Bypass -File tool\build_portable.ps1
```

Script build ứng dụng Windows, tải Python Embedded, cài toàn bộ dependency
backend vào gói và tạo `build\portable\LingoSnap-windows-x64.zip`. Trên máy
khác chỉ cần giải nén toàn bộ ZIP rồi chạy `LingoSnap\capture_translate_tool.exe`;
không cần Git, Flutter, Python hay Internet.

> Gói `screen_capturer` trên Windows yêu cầu Visual Studio workload Desktop
> development with C++ và ATL.
