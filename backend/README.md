# LingoSnap backend

Mã nguồn backend nằm ở `native/` (C++). Thư mục này chỉ chứa model tải về trong
`backend/models/` (không commit): chạy `tool\setup_models.ps1` để tải PP-OCRv6 small ONNX,
gói dịch Argos English→Vietnamese và LanguageTool 6.8. `tool\convert_vinai.ps1` (cần Python, một lần)
tạo thêm `backend/models/vinai-en-vi` (VinAI Translate en2vi v2, AGPL-3.0); khi có, backend dùng model
này thay cho Argos.
