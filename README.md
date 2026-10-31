# Ads Agent by: noti.vn — cài đặt nhanh lên VPS

Dán **1 dòng** này vào terminal VPS (Ubuntu 22.04 / 24.04 hoặc Debian 12 / 13, quyền root):

```bash
curl -fsSL https://raw.githubusercontent.com/notivn/ads-agent-simple-install/main/deploy.sh | sudo bash
```

Script tự làm hết, chỉ hỏi bạn vài câu:

1. **Kiểm tra máy** và hiện bảng ✔ / ⚠ / ✖ cho từng mục:
   - quyền root, hệ điều hành, CPU;
   - RAM, swap, ổ đĩa;
   - DNS, kết nối GitHub (SSH và HTTPS), Docker Hub;
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
   - cách lấy mã nguồn từ repo riêng tư:
     - **Deploy key**: script in ra dòng `ssh-ed25519 …`, bạn dán vào repo → Settings → Deploy keys (không tick write), rồi gõ **Y** + Enter;
     - hoặc **username + token classic** có quyền `repo`.
3. **Tự cài và chạy**:
   - cài Docker nếu chưa có;
   - tạo swap nếu thiếu RAM;
   - mở tường lửa;
   - tải mã nguồn;
   - tạo `.env` với secret ngẫu nhiên;
   - build và chạy;
   - kiểm tra sức khoẻ.
4. **In ra địa chỉ** `https://<tên miền>/setup` cùng **mã thiết lập**, để bạn tạo tài khoản quản trị đầu tiên.

Sau khi cài:

| Lệnh | Việc |
| --- | --- |
| `sudo ads-agent-deploy update` | Sao lưu database, kéo mã mới nhất, build lại, khởi động lại (giữ dữ liệu) |
| `sudo ads-agent-deploy reconfigure` | Đổi cách truy cập Internet |
| `sudo ads-agent-deploy setup-key` | Xem lại mã thiết lập |
| `sudo ads-agent status` · `logs web` · `backup` | Trạng thái, nhật ký, sao lưu |

## Về repo này

- Repo chỉ chứa **script cài đặt** `deploy.sh`, không có mã nguồn ứng dụng và không có bí mật nào. Mã nguồn Ads Agent nằm ở repo riêng tư `notivn/Ads-Agent-Simple` và chỉ được tải bằng Deploy key hoặc token của bạn.
- `deploy.sh` là bản chép nguyên `scripts/deploy-vps.sh` của repo chính. Muốn sửa thì sửa ở repo chính rồi chép sang đây.
- Bí mật (token GitHub, token tunnel, khoá riêng Origin Certificate, nội dung `.env`) không bao giờ hiện trên màn hình, ghi vào nhật ký hay nằm trong URL / tham số lệnh. Nhật ký cài đặt: `/var/log/ads-agent-deploy.log`.

© 2026 noti.vn. Script phát hành kèm sản phẩm Ads Agent theo giấy phép của sản phẩm.
