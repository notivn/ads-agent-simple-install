# Ads Agent by: noti.vn — cài đặt nhanh lên VPS

Dán **1 dòng** này vào terminal VPS (Ubuntu 22.04 / 24.04 hoặc Debian 12 / 13, quyền root):

```bash
curl -fsSL https://raw.githubusercontent.com/notivn/ads-agent-simple-install/main/deploy.sh | sudo bash
```

Script tự làm hết, chỉ hỏi bạn vài câu:

1. **Kiểm tra máy** và hiện bảng ✔ / ⚠ / ✖ cho từng mục:
   - quyền root, hệ điều hành, CPU;
   - RAM, swap, ổ đĩa;
   - DNS, kết nối GitHub qua HTTPS, Docker Hub;
   - kết nối Telegram (chỉ cảnh báo: nhà mạng chặn Telegram thì bot nhận tin nhưng không trả lời được);
   - Docker và Compose;
   - cổng 80 / 443;
   - đồng hồ hệ thống, tường lửa;
   - Ads MCP và bản cài cũ trên máy.

   Mục nào phải sửa thì script dừng và chỉ cách sửa.
2. **Hỏi thông tin**:
   - tên miền và email;
   - cách đưa web ra Internet:
     - **1** Cloudflare Tunnel: dán token, không cần mở cổng, dùng được khi VPS đang chạy Ads MCP;
     - **2** Trỏ bản ghi A về IP VPS: SSL tự cấp (Let's Encrypt);
     - **3** Proxy Cloudflare: dán Origin Certificate và Private Key;
   - **username + token classic GitHub** (quyền `repo`, gõ ẩn) của tài khoản được mời vào repo riêng tư. Khuyến nghị: tài khoản GitHub riêng cho máy chủ, chỉ được mời quyền Read — script cảnh báo nếu token có quyền ghi;
   - chỉ khi máy không gọi được Telegram: địa chỉ proxy Telegram (`TELEGRAM_API_BASE_URL`, ví dụ Cloudflare Worker `https://tg-proxy.ten.workers.dev`), bỏ trống được.
3. **Tự cài và chạy**:
   - cài Docker nếu chưa có;
   - tạo swap nếu thiếu RAM;
   - mở tường lửa;
   - tải mã nguồn;
   - tạo `.env` với secret ngẫu nhiên, username + token GitHub và nguồn cập nhật (quyền 600, chỉ root đọc được);
   - build và chạy (kể cả dịch vụ cập nhật);
   - kiểm tra sức khoẻ.
4. **In ra địa chỉ** `https://<tên miền>/setup` cùng **mã thiết lập**, để bạn tạo tài khoản quản trị đầu tiên. Xác thực 2 bước là tuỳ chọn: bật trong Tài khoản nếu muốn (khuyến nghị).

## Cập nhật bản mới

Sau khi cài, bản mới là phiên bản ghi trong `package.json` ở đầu nhánh `main` của repo riêng tư. Khi có bản mới, trang **Tổng quan** hiện thẻ **Có bản cập nhật**: bấm **Cập nhật ngay**. Máy chủ tự tải mã mới bằng token trong `.env`, build (web vẫn chạy), sao lưu, cập nhật cơ sở dữ liệu, khởi động lại (~1 phút) và tự quay về bản cũ nếu lỗi.

## Lệnh sau khi cài

| Lệnh | Việc |
| --- | --- |
| `sudo ads-agent-deploy update` | Sao lưu database, kéo mã mới nhất, build lại, khởi động lại (giữ dữ liệu) |
| `sudo ads-agent-deploy token` | Đổi username / token GitHub (token hết hạn, đổi tài khoản) |
| `sudo ads-agent-deploy reconfigure` | Đổi cách truy cập Internet, đặt / bỏ proxy Telegram |
| `sudo ads-agent-deploy setup-key` | Xem lại mã thiết lập |
| `sudo ads-agent status` · `logs web` · `backup` | Trạng thái, nhật ký, sao lưu |

Bản cài cũ dùng Deploy key: chạy `sudo ads-agent-deploy update`, nhập username + token khi được hỏi. Script tự chuyển sang token, gỡ khoá cũ trên máy và bật nút cập nhật trên web; sau đó xoá Deploy key trên GitHub (Settings → Deploy keys của repo).

## Về repo này

- Repo chỉ chứa **script cài đặt** `deploy.sh`, không có mã nguồn ứng dụng và không có bí mật nào. Mã nguồn Ads Agent nằm ở repo riêng tư `notivn/Ads-Agent-Simple` và chỉ được tải bằng username + token của bạn.
- `deploy.sh` là bản chép nguyên `scripts/deploy-vps.sh` của repo chính. Muốn sửa thì sửa ở repo chính rồi chép sang đây.
- Bí mật (token GitHub, token tunnel, khoá riêng Origin Certificate, nội dung `.env`) không bao giờ hiện trên màn hình, ghi vào nhật ký hay nằm trong URL / tham số lệnh. Nhật ký cài đặt: `/var/log/ads-agent-deploy.log`.

© 2026 noti.vn. Script phát hành kèm sản phẩm Ads Agent theo giấy phép của sản phẩm.
