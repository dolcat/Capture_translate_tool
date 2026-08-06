# Tóm tắt ý tưởng ứng dụng OCR và dịch offline trên Windows

**Công nghệ chính:** PaddleOCR + CTranslate2 + MarianMT

> **Mục tiêu:** Tạo một công cụ chạy trên Windows cho phép người dùng dùng phím tắt để chọn một vùng màn hình, nhận dạng chữ trong ảnh và dịch nội dung sang tiếng Việt hoàn toàn offline.

## 1. Mục tiêu sản phẩm

- Chạy trực tiếp trên Windows, không phụ thuộc Internet sau khi đã cài ứng dụng và model.
- Cho phép kéo chọn một vùng trên màn hình tương tự Snipping Tool.
- Nhận dạng chữ trong ảnh bằng PaddleOCR.
- Dịch văn bản sang tiếng Việt bằng MarianMT chạy qua CTranslate2.
- Hiển thị kết quả bằng cửa sổ popup, sao chép vào clipboard hoặc overlay tại vị trí chữ gốc.

## 2. Luồng hoạt động chính

| Bước | Xử lý |
|---|---|
| 1 | Người dùng nhấn phím tắt toàn hệ thống. |
| 2 | Ứng dụng hiển thị lớp phủ và cho phép kéo chọn vùng cần dịch. |
| 3 | Ứng dụng chụp ảnh vùng đã chọn. |
| 4 | PaddleOCR nhận dạng nội dung chữ và tọa độ từng vùng chữ. |
| 5 | Văn bản được làm sạch, ghép dòng và đưa vào engine dịch. |
| 6 | CTranslate2 chạy model MarianMT để dịch sang tiếng Việt. |
| 7 | Kết quả được hiển thị trong popup hoặc overlay và có thể sao chép. |

## 3. Kiến trúc đề xuất

```text
Flutter Windows UI
    → Screen Capture
    → PaddleOCR
    → Text Processor
    → CTranslate2 + MarianMT
    → Popup / Overlay
```

| Thành phần | Công nghệ | Vai trò |
|---|---|---|
| Giao diện | Flutter Desktop | Hiển thị cửa sổ chính, cài đặt, lịch sử và kết quả dịch. |
| Chụp màn hình | Windows Graphics Capture / Win32 | Chụp toàn màn hình hoặc vùng người dùng lựa chọn. |
| OCR | PaddleOCR | Nhận dạng chữ, độ tin cậy và tọa độ bounding box. |
| Dịch offline | CTranslate2 + MarianMT | Chạy model dịch nhanh trên CPU hoặc GPU mà không cần Internet. |
| Backend local | Python service hoặc process nhúng | Điều phối OCR, xử lý văn bản và dịch. |
| Lưu trữ | SQLite | Lưu lịch sử, cache bản dịch và tùy chọn người dùng. |

## 4. Vai trò của PaddleOCR

- Nhận dạng chữ từ ảnh chụp màn hình.
- Trả về nội dung chữ, độ tin cậy và tọa độ của từng vùng.
- Hỗ trợ nhiều ngôn ngữ và phù hợp với chữ trong giao diện, tài liệu, game hoặc video.
- Nên ghép các từ thành dòng hoặc đoạn trước khi gửi sang model dịch để giữ ngữ cảnh.

## 5. Vai trò của CTranslate2 và MarianMT

- MarianMT là model dịch máy chuyên dụng cho từng cặp ngôn ngữ, ví dụ English → Vietnamese.
- CTranslate2 là runtime tối ưu để chạy model nhanh hơn và dùng ít RAM hơn.
- Có thể dùng quantization INT8 để cải thiện hiệu năng trên máy chỉ có CPU.
- Model được lưu cục bộ trong máy; sau khi cài đặt không cần gọi API hoặc kết nối Internet.
- MVP nên bắt đầu với một cặp ngôn ngữ cố định, ưu tiên English → Vietnamese để giảm dung lượng và độ phức tạp.

## 6. API nội bộ gợi ý

Ứng dụng Flutter có thể giao tiếp với local service qua HTTP localhost hoặc stdin/stdout.

```http
POST /analyze
Content-Type: application/json
```

```json
{
  "imagePath": "capture.png",
  "sourceLanguage": "en",
  "targetLanguage": "vi"
}
```

Phản hồi:

```json
{
  "items": [
    {
      "original": "Press E to continue",
      "translated": "Nhấn E để tiếp tục",
      "confidence": 0.96,
      "box": [120, 300, 420, 340]
    }
  ]
}
```

## 7. Phạm vi MVP

- Chỉ hỗ trợ Windows 10/11.
- Phím tắt để chọn một vùng màn hình.
- OCR tiếng Anh bằng PaddleOCR.
- Dịch English → Vietnamese bằng MarianMT + CTranslate2.
- Hiển thị kết quả trong popup.
- Nút sao chép, chụp lại và đóng.
- Lưu lịch sử và cache bản dịch trong SQLite.

## 8. Hướng mở rộng

- Overlay bản dịch đúng vị trí chữ gốc dựa trên bounding box.
- Dịch liên tục một vùng màn hình cho game hoặc video.
- Thêm model Nhật, Trung, Hàn sang tiếng Việt.
- Tự phát hiện ngôn ngữ nguồn.
- Từ điển tùy chỉnh và glossary theo lĩnh vực.
- Dịch ảnh, PDF và nội dung clipboard.
- Đóng gói toàn bộ Flutter, Python runtime và model thành bộ cài Windows.

## 9. Lưu ý kỹ thuật

- Không gửi từng từ riêng lẻ sang model dịch; nên ghép thành câu hoặc đoạn.
- Giữ liên kết giữa đoạn văn bản và bounding box để hỗ trợ overlay về sau.
- Nạp model một lần khi ứng dụng khởi động thay vì nạp lại cho mỗi lần dịch.
- Dùng cache theo nội dung và cặp ngôn ngữ để giảm thời gian xử lý.
- Cần kiểm tra license của model MarianMT cụ thể trước khi phát hành thương mại.
- Nên cung cấp màn hình quản lý model vì mỗi cặp ngôn ngữ có model riêng.

## 10. Kết luận

Cấu hình đề xuất cho phiên bản đầu tiên:

```text
Flutter Windows
+ Windows Screen Capture
+ PaddleOCR
+ Python local service
+ CTranslate2 INT8
+ MarianMT English–Vietnamese
+ SQLite
```

Kiến trúc này đáp ứng yêu cầu chạy offline, dễ kiểm thử từng thành phần và có thể mở rộng sang overlay hoặc nhiều ngôn ngữ mà không cần thay đổi toàn bộ ứng dụng.
