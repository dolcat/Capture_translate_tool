# LingoSnap local backend

Backend chạy hoàn toàn trên máy và cung cấp:

- `GET /health`
- `POST /analyze`
- `POST /translate`
- `POST /grammar`
- `POST /grammar/warmup`

Thiết lập lần đầu trên Windows:

LanguageTool local yêu cầu Java 17. Cài Java 17 trước, sau đó chạy:

```powershell
powershell -ExecutionPolicy Bypass -File backend\setup_backend.ps1
```

Chạy thủ công để kiểm tra:

```powershell
python backend\server.py
```

Flutter tự khởi động `server.py` khi người dùng bắt đầu xử lý ảnh. Gói dịch
offline Argos English→Vietnamese, model PP-OCRv5 mobile định dạng ONNX cho detection,
English recognition và LanguageTool 6.8 đều được lưu trong `backend/models`. Sau bước
thiết lập đầu tiên, backend không cần Internet.
