# LingoSnap local backend

Backend chạy hoàn toàn trên máy và cung cấp:

- `GET /health`
- `POST /analyze`
- `POST /translate`

Thiết lập lần đầu trên Windows:

```powershell
powershell -ExecutionPolicy Bypass -File backend\setup_backend.ps1
```

Chạy thủ công để kiểm tra:

```powershell
python backend\server.py
```

Flutter tự khởi động `server.py` khi người dùng bắt đầu xử lý ảnh. Gói dịch
offline Argos English→Vietnamese, model PP-OCRv5 mobile định dạng ONNX cho detection
và English recognition đều được lưu trong `backend/models`. Sau bước thiết lập đầu
tiên, backend không cần Internet.
