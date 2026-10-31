#!/usr/bin/env bash
# Ads Agent by: noti.vn - triển khai nhanh lên VPS từ repo GitHub riêng tư (build image ngay trên VPS).
#
#   curl -fsSL https://raw.githubusercontent.com/notivn/ads-agent-simple-install/main/deploy.sh | sudo bash
#                                        # 1 dòng: dán vào terminal VPS là chạy (file công khai, không chứa bí mật)
#   sudo bash deploy-vps.sh              # hoặc chạy file đã có trên máy: cài mới; đã cài thì hỏi cập nhật / đổi cách truy cập
#   sudo ads-agent-deploy update         # kéo mã mới nhất + build lại + khởi động lại (dữ liệu giữ nguyên)
#   sudo ads-agent-deploy reconfigure    # đổi cách đưa web ra Internet (Tunnel / trỏ IP / proxy Cloudflare)
#   sudo ads-agent-deploy setup-key      # in lại mã thiết lập (SETUP_TOKEN) để tạo quản trị viên đầu tiên
# Sau lần cài đầu, script được chép thành lệnh `sudo ads-agent-deploy <lệnh>`.
#
# Các bước: bảng kiểm tra máy (root, OS, RAM/ổ đĩa, mạng GitHub/Docker Hub, Docker, cổng 80/443, đồng hồ, tường lửa,
# Ads MCP) → hỏi tên miền + cách truy cập + cách lấy mã nguồn → cài Docker → quyền đọc repo: Deploy key (in ra để
# dán vào GitHub → Settings → Deploy keys, rồi gõ Y + Enter) HOẶC username + token classic (quyền repo) → tải mã
# nguồn → tạo .env (secret ngẫu nhiên) → chứng chỉ / token theo cách truy cập → build 3 image → chạy → kiểm tra sức
# khoẻ → in địa chỉ /setup và mã thiết lập. Bản công khai deploy.sh ở repo notivn/ads-agent-simple-install là bản
# chép NGUYÊN file này (nguồn duy nhất: scripts/deploy-vps.sh của repo chính).
# 3 cách truy cập Internet (.claude/docs/13-deployment.md §3):
#   1 Cloudflare Tunnel  - không mở cổng, dán token tunnel (dùng được cả khi VPS đang chạy Ads MCP Simple)
#   2 Trỏ IP về VPS      - bản ghi A → IP VPS, hệ thống tự xin chứng chỉ SSL Let's Encrypt (cần cổng 80/443 trống)
#   3 Proxy Cloudflare   - bản ghi A mây cam, dán Origin Certificate + Private key của Cloudflare (SSL Full strict)
# Bí mật (token GitHub, token tunnel, khoá riêng Origin, nội dung .env) không bao giờ in ra màn hình, ghi log hay
# nằm trong tham số lệnh / URL / .git/config. Log: /var/log/ads-agent-deploy.log.
# Không đụng tới Ads MCP Simple: thư mục, mạng, volume, Caddyfile, docker login của nó đều giữ nguyên.
# Ghi chú: image tự build không có chữ ký số phát hành nên tính năng "Cập nhật 1 nút" trên web (updater) được tắt;
# cập nhật bằng `sudo ads-agent-deploy update`. Khi đã có bản phát hành chính thức trên GHCR, dùng
# scripts/install-ads-agent.sh để chuyển sang chế độ kéo image + cập nhật 1 nút.

set -Eeuo pipefail

REPO="${ADS_AGENT_REPO:-notivn/Ads-Agent-Simple}"
BRANCH="${ADS_AGENT_BRANCH:-main}"
DIR="${ADS_AGENT_DIR:-/opt/ads-agent}"
KEY="/root/.ssh/ads_agent_deploy_ed25519"
KNOWN_HOSTS="/root/.ssh/known_hosts_ads_agent"
# Fingerprint khoá máy chủ ed25519 của github.com (GitHub công bố tại docs.github.com: "GitHub's SSH key fingerprints")
GITHUB_ED25519_FP="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"
LOG="/var/log/ads-agent-deploy.log"
CONF="/etc/ads-agent.conf"
SELF_BIN="/usr/local/bin/ads-agent-deploy"
HELPER_BIN="/usr/local/bin/ads-agent"
MIN_MEM_MB=4096 # RAM + swap tối thiểu để build image Next.js trên VPS

DOMAIN="" EMAIL="" ACCESS="" GATEWAYS=1 TUNNEL_TOKEN_VALUE="" CERT_PEM="" KEY_PEM="" PUBLIC_IP=""
PORTS_BUSY=0 PORTS_BUSY_BY="" OS_ID="" TMPD="" GH_SSH_HOST=github.com GH_SSH_PORT=22

# ------------------------------------------------------------------------------------------------------------------
# Giao diện
# ------------------------------------------------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YLW=$'\e[33m' C_BLU=$'\e[36m' C_BLD=$'\e[1m' C_DIM=$'\e[2m' C_RST=$'\e[0m'
else
  C_RED="" C_GRN="" C_YLW="" C_BLU="" C_BLD="" C_DIM="" C_RST=""
fi
log() { { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; } 2>/dev/null || true; }
say() { printf '%s\n' "$*"; log "$*"; }
info() { printf '   %s\n' "$*"; log "   $*"; }
ok() { printf '   %s✔%s %s\n' "$C_GRN" "$C_RST" "$*"; log "   OK $*"; }
warn() { printf '   %s⚠%s %s\n' "$C_YLW" "$C_RST" "$*"; log "   WARN $*"; }
die() {
  printf '\n%s✖ %s%s\n' "$C_RED$C_BLD" "$*" "$C_RST" >&2
  log "FATAL $*"
  printf '   Nhật ký chi tiết: %s\n' "$LOG" >&2
  exit 1
}
STEP_N=0 STEP_TOTAL=10
step() {
  STEP_N=$((STEP_N + 1))
  printf '\n%s[%s/%s] %s%s\n' "$C_BLU$C_BLD" "$STEP_N" "$STEP_TOTAL" "$*" "$C_RST"
  log "== [$STEP_N/$STEP_TOTAL] $*"
}
cleanup() { [[ -n "$TMPD" && -d "$TMPD" ]] && rm -rf "$TMPD"; return 0; }
trap cleanup EXIT
trap 'die "Lỗi không mong muốn ở dòng $LINENO (lệnh: ${BASH_COMMAND%% *})."' ERR

# Mọi câu hỏi đọc từ bàn phím (/dev/tty), kể cả khi script được chạy qua đường ống (curl … | sudo bash).
tty_ok() { { : </dev/tty; } 2>/dev/null; }
# Ctrl+D / mất kết nối SSH khi đang hỏi: dừng gọn (chạy lại đúng lệnh cũ là làm tiếp, dữ liệu đã có giữ nguyên)
tty_closed() { die "Đã dừng (không đọc được bàn phím). Chạy lại đúng lệnh cũ để làm tiếp."; }
ask() { # ask "Câu hỏi" "mặc định" -> REPLY
  local q=$1 def=${2:-} ans=""
  if [[ -n "$def" ]]; then
    read -r -p "   $q [$def]: " ans </dev/tty || tty_closed
    REPLY=${ans:-$def}
  else
    read -r -p "   $q: " ans </dev/tty || tty_closed
    REPLY=$ans
  fi
}
ask_yn() { # ask_yn "Câu hỏi" Y|N -> 0 = có
  local q=$1 def=${2:-N} ans="" hint="[y/N]"
  [[ "$def" == "Y" ]] && hint="[Y/n]"
  read -r -p "   $q $hint: " ans </dev/tty || tty_closed
  ans=${ans:-$def}
  [[ "$ans" =~ ^[YyCc] ]]
}
ask_secret() { # ask_secret "Câu hỏi" -> REPLY (không hiện ký tự gõ)
  local ans=""
  read -r -s -p "   $1: " ans </dev/tty || tty_closed
  printf '\n'
  REPLY=$ans
}
# read_pem "BEGIN-regex" "END-regex" -> REPLY: đọc khối PEM dán vào terminal, dừng ở dòng END (không in lại nội dung)
read_pem() {
  local begin=$1 end=$2 line buf="" started=0
  while IFS= read -r line </dev/tty; do
    line=${line%$'\r'}
    [[ $started -eq 0 && -z "${line// /}" ]] && continue
    if [[ $started -eq 0 ]]; then
      [[ "$line" =~ $begin ]] || { warn "Dòng đầu phải là -----BEGIN …----- . Dán lại từ đầu."; buf=""; continue; }
      started=1
    fi
    buf+="$line"$'\n'
    [[ "$line" =~ $end ]] && break
  done
  REPLY=$buf
}

# .env: đọc/ghi bằng bash thuần (giá trị không bao giờ nằm trong tham số của tiến trình khác)
env_get() { # env_get KEY [file]
  local key=$1 file=${2:-$DIR/.env} line
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$key="* ]]; then
      line=${line#"$key="}
      line=${line%$'\r'}
      line=${line#\"}
      line=${line%\"}
      printf '%s' "$line"
      return 0
    fi
  done <"$file"
}
env_set() { # env_set KEY VALUE [file]
  local key=$1 value=$2 file=${3:-$DIR/.env} line done=0 tmp
  local -a lines=()
  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ $done -eq 0 && ("$line" == "$key="* || "$line" == "# $key="*) ]]; then
        lines+=("$key=$value")
        done=1
      else
        lines+=("$line")
      fi
    done <"$file"
  fi
  [[ $done -eq 1 ]] || lines+=("$key=$value")
  tmp="$file.tmp.$$"
  (
    umask 077
    printf '%s\n' "${lines[@]}" >"$tmp"
  )
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}

run_logged() { # run_logged "mô tả" lệnh... : chạy, ghi log; lỗi thì in 25 dòng cuối
  local desc=$1
  shift
  log "\$ $desc"
  if ! "$@" >>"$LOG" 2>&1; then
    printf '%s--- 25 dòng cuối của nhật ký ---%s\n' "$C_DIM" "$C_RST" >&2
    tail -n 25 "$LOG" >&2 || true
    return 1
  fi
}

# Git qua SSH bằng Deploy key riêng của Ads Agent (không sửa ~/.ssh/config, không dùng khoá khác của máy)
GIT_SSH="ssh -i $KEY -o IdentitiesOnly=yes -o UserKnownHostsFile=$KNOWN_HOSTS -o StrictHostKeyChecking=yes -o BatchMode=yes"
git_ssh() { GIT_SSH_COMMAND="$GIT_SSH" GIT_TERMINAL_PROMPT=0 git "$@"; }
repo_ssh_url() {
  if [[ "$GH_SSH_PORT" == "22" ]]; then
    printf 'git@github.com:%s.git' "$REPO"
  else
    printf 'ssh://git@%s:%s/%s.git' "$GH_SSH_HOST" "$GH_SSH_PORT" "$REPO"
  fi
}

dc_build() { (cd "$DIR" && docker compose -f docker-compose.yml -f docker-compose.build.yml "$@"); }

# ------------------------------------------------------------------------------------------------------------------
# Kiểm tra máy
# ------------------------------------------------------------------------------------------------------------------
os_field() { sed -n "s/^$1=//p" /etc/os-release | tr -d '"' | head -n 1; }

# tcp_ok HOST PORT: mở được kết nối TCP trong 6 giây (bash /dev/tcp, không cần nc/telnet)
tcp_ok() { timeout 6 bash -c ": </dev/tcp/$1/$2" >/dev/null 2>&1; }

# Bảng kiểm tra trước khi cài: ✔ đạt · ⚠ cảnh báo (vẫn cài được) · ✖ lỗi chặn (dừng, kèm cách sửa)
PF_FAIL=0
pf_ok() { ok "$*"; }
pf_warn() { warn "$*"; }
pf_fail() {
  printf '   %s✖%s %s\n' "$C_RED" "$C_RST" "$*"
  log "   FAIL $*"
  PF_FAIL=$((PF_FAIL + 1))
}

precheck() {
  step "Kiểm tra máy chủ trước khi cài"
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Cần quyền root. Chạy lại với sudo (hoặc đăng nhập root)."
  tty_ok || die "Script cần bàn phím để hỏi thông tin. Hãy chạy trực tiếp trong terminal SSH."
  : >>"$LOG" 2>/dev/null && chmod 600 "$LOG" 2>/dev/null || LOG=/dev/null
  pf_ok "Quyền root"

  # --- hệ điều hành, kiến trúc
  if [[ ! -f /etc/os-release ]]; then
    pf_fail "Không đọc được /etc/os-release. Cần Ubuntu 22.04/24.04 hoặc Debian 12/13."
  else
    OS_ID=$(os_field ID)
    case "$OS_ID" in
      ubuntu | debian) pf_ok "Hệ điều hành: $(os_field PRETTY_NAME)" ;;
      *) pf_fail "Hệ điều hành $(os_field PRETTY_NAME) chưa hỗ trợ. Cần Ubuntu 22.04/24.04 hoặc Debian 12/13." ;;
    esac
  fi
  local arch
  arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
  case "$arch" in
    amd64 | arm64) pf_ok "Kiến trúc CPU: $arch" ;;
    *) pf_fail "Kiến trúc $arch chưa hỗ trợ (cần amd64 hoặc arm64)." ;;
  esac

  # --- RAM, swap, ổ đĩa
  local mem_mb swap_mb disk_gb
  mem_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
  swap_mb=$(awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo)
  disk_gb=$(df -BG --output=avail / 2>/dev/null | tail -n 1 | tr -dc '0-9' || true)
  if [[ $mem_mb -lt 1800 ]]; then
    pf_fail "RAM ${mem_mb} MB: cần tối thiểu 2 GB. Nâng cấp gói VPS."
  elif [[ $((mem_mb + swap_mb)) -lt $MIN_MEM_MB ]]; then
    pf_ok "RAM ${mem_mb} MB, swap ${swap_mb} MB (script sẽ tự tạo thêm swap để build)"
  else
    pf_ok "RAM ${mem_mb} MB, swap ${swap_mb} MB"
  fi
  if [[ ${disk_gb:-0} -lt 10 ]]; then
    pf_fail "Ổ đĩa trống ${disk_gb:-?} GB: cần ≥ 10 GB (khuyến nghị 15 GB). Dọn bớt (docker system prune) hoặc tăng ổ đĩa."
  elif [[ ${disk_gb:-0} -lt 15 ]]; then
    pf_warn "Ổ đĩa trống ${disk_gb} GB: đủ chạy nhưng sát. Khuyến nghị ≥ 15 GB."
  else
    pf_ok "Ổ đĩa trống ${disk_gb} GB"
  fi

  # --- mạng ra Internet
  if getent ahosts github.com >/dev/null 2>&1; then pf_ok "DNS của VPS phân giải được tên miền"; else
    pf_fail "VPS không phân giải được github.com. Kiểm tra /etc/resolv.conf (thử nameserver 1.1.1.1)."
  fi
  GH_SSH_OK=1 GH_HTTPS_OK=1
  if tcp_ok github.com 22; then
    GH_SSH_HOST=github.com GH_SSH_PORT=22
    pf_ok "Kết nối GitHub qua SSH (github.com:22) - dùng được Deploy key"
  elif tcp_ok ssh.github.com 443; then
    GH_SSH_HOST=ssh.github.com GH_SSH_PORT=443
    pf_ok "Cổng 22 ra ngoài bị chặn → Deploy key đi qua ssh.github.com:443"
  else
    GH_SSH_OK=0
  fi
  tcp_ok github.com 443 && tcp_ok api.github.com 443 || GH_HTTPS_OK=0
  if [[ $GH_HTTPS_OK -eq 1 ]]; then pf_ok "Kết nối GitHub qua HTTPS (github.com:443) - dùng được token"; fi
  if [[ $GH_SSH_OK -eq 0 && $GH_HTTPS_OK -eq 0 ]]; then
    pf_fail "Không kết nối được GitHub (cả SSH lẫn HTTPS). Mở kết nối ra ngoài ở tường lửa VPS."
  elif [[ $GH_SSH_OK -eq 0 ]]; then
    pf_warn "Không vào được GitHub qua SSH → chỉ dùng được cách lấy mã bằng username + token."
  fi
  if tcp_ok registry-1.docker.io 443; then pf_ok "Kết nối Docker Hub (tải image cơ sở)"; else
    pf_fail "Không kết nối được Docker Hub (registry-1.docker.io:443): không tải được image PostgreSQL/Caddy."
  fi

  # --- đồng hồ (xác thực 2 bước TOTP và chứng chỉ SSL cần giờ đúng)
  local ntp
  ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
  if [[ "$ntp" == "yes" ]]; then
    pf_ok "Đồng hồ hệ thống đã đồng bộ (NTP)"
  else
    timedatectl set-ntp true >/dev/null 2>&1 || true
    pf_warn "Đồng hồ chưa đồng bộ NTP (đã bật tự đồng bộ). Giờ lệch làm mã 2FA và SSL báo lỗi."
  fi

  # --- Docker
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1 || systemctl start docker >/dev/null 2>&1; then
      pf_ok "Docker $(docker --version 2>/dev/null | sed 's/.*version \([^,]*\).*/\1/') + Compose $(docker compose version --short 2>/dev/null) đang chạy"
    else
      pf_warn "Đã có Docker nhưng dịch vụ không chạy (script sẽ thử khởi động lại)."
    fi
  else
    if tcp_ok download.docker.com 443; then
      pf_ok "Chưa có Docker → script sẽ tự cài bản chính thức (download.docker.com)"
    else
      pf_fail "Chưa có Docker và không tải được từ download.docker.com:443. Mở kết nối ra ngoài rồi chạy lại."
    fi
  fi

  # --- cổng 80/443
  if ss -ltnH '( sport = :80 or sport = :443 )' 2>/dev/null | grep -q .; then
    PORTS_BUSY=1
    PORTS_BUSY_BY=$(ss -ltnpH '( sport = :80 or sport = :443 )' 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | sort -u | tr '\n' ' ' || true)
    if [[ -f "$DIR/.env" ]] && (cd "$DIR" && docker compose ps --status running --services 2>/dev/null | grep -qx caddy); then
      PORTS_BUSY=0
      pf_ok "Cổng 80/443 đang do chính Ads Agent dùng"
    else
      pf_warn "Cổng 80/443 đang bị dùng bởi: ${PORTS_BUSY_BY:-chương trình khác} → chỉ dùng được cách 1 (Cloudflare Tunnel)."
    fi
  else
    pf_ok "Cổng 80/443 còn trống"
  fi

  # --- tường lửa, phần mềm khác trên máy
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    pf_ok "Tường lửa UFW đang bật (script tự mở 80/443 khi cần)"
  else
    pf_ok "Tường lửa UFW không bật (nhớ mở 80/443 ở tường lửa của nhà cung cấp VPS nếu dùng cách 2/3)"
  fi
  if [[ -d /opt/ads-mcp || -f /etc/ads-mcp.conf ]]; then
    pf_ok "Có Ads MCP Simple trên máy: script không đụng tới nó (thư mục, mạng, chứng chỉ giữ nguyên)"
  fi
  if command -v apt-get >/dev/null 2>&1; then pf_ok "Có apt-get (cài gói tự động)"; else pf_fail "Không có apt-get."; fi

  if [[ $PF_FAIL -gt 0 ]]; then
    die "Có $PF_FAIL lỗi ở bảng kiểm tra (dấu ✖). Sửa theo gợi ý rồi chạy lại đúng lệnh cũ."
  fi
  ok "Máy chủ đạt yêu cầu."
}

ensure_swap() {
  local mem_mb swap_mb need_mb size_mb
  mem_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
  swap_mb=$(awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo)
  need_mb=$((MIN_MEM_MB - mem_mb - swap_mb))
  [[ $need_mb -gt 0 ]] || { ok "RAM + swap đủ để build (${mem_mb} + ${swap_mb} MB)"; return 0; }
  size_mb=$(((need_mb / 1024 + 1) * 1024))
  [[ $size_mb -ge 2048 ]] || size_mb=2048
  if [[ -f /swapfile-ads-agent ]]; then
    warn "Đã có /swapfile-ads-agent nhưng RAM + swap vẫn dưới $MIN_MEM_MB MB. Build có thể chậm."
    return 0
  fi
  info "RAM + swap dưới $MIN_MEM_MB MB: tạo thêm swap ${size_mb} MB để build không bị thiếu bộ nhớ…"
  run_logged "fallocate swap" fallocate -l "${size_mb}M" /swapfile-ads-agent ||
    run_logged "dd swap" dd if=/dev/zero of=/swapfile-ads-agent bs=1M count="$size_mb" ||
    die "Không tạo được file swap (thiếu dung lượng ổ đĩa?)."
  chmod 600 /swapfile-ads-agent
  run_logged "mkswap" mkswap /swapfile-ads-agent || die "mkswap thất bại."
  run_logged "swapon" swapon /swapfile-ads-agent || die "swapon thất bại."
  grep -q '^/swapfile-ads-agent ' /etc/fstab || printf '/swapfile-ads-agent none swap sw 0 0\n' >>/etc/fstab
  ok "Đã bật swap ${size_mb} MB (/swapfile-ads-agent, tự bật lại khi khởi động máy)"
}

# ------------------------------------------------------------------------------------------------------------------
# Hỏi cấu hình
# ------------------------------------------------------------------------------------------------------------------
valid_domain() { [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_email() { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }

ask_domain_email() {
  while :; do
    ask "Tên miền cho Ads Agent (vd agent.congty.vn)" "$(env_get APP_DOMAIN)"
    DOMAIN=$(printf '%s' "$REPLY" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    DOMAIN=${DOMAIN#https://}
    DOMAIN=${DOMAIN#http://}
    DOMAIN=${DOMAIN%%/*}
    valid_domain "$DOMAIN" && break
    warn "Tên miền không hợp lệ. Ví dụ đúng: agent.congty.vn"
  done
  while :; do
    ask "Email quản trị (nhận thông báo chứng chỉ SSL)" "$(env_get ACME_EMAIL)"
    EMAIL=$(printf '%s' "$REPLY" | tr -d '[:space:]')
    valid_email "$EMAIL" && break
    warn "Email không hợp lệ."
  done
}

ask_access() {
  say ""
  say "   ${C_BLD}Chọn cách đưa web ra Internet:${C_RST}"
  say "     1) Cloudflare Tunnel  — không cần mở cổng, dán token tunnel của Cloudflare"
  say "     2) Trỏ bản ghi A về IP VPS — hệ thống tự cấp SSL (Let's Encrypt), cần cổng 80/443"
  say "     3) Proxy Cloudflare (mây cam) — dán Origin Certificate + Private key của Cloudflare"
  local def=2
  if [[ $PORTS_BUSY -eq 1 ]]; then
    def=1
    warn "Cổng 80/443 đang bận nên chỉ cách 1 (Cloudflare Tunnel) chạy được mà không đụng chương trình đang dùng cổng."
  fi
  while :; do
    ask "Chọn 1, 2 hoặc 3" "$def"
    case "$REPLY" in
      1) ACCESS=tunnel ;;
      2) ACCESS=auto ;;
      3) ACCESS=cloudflare ;;
      *)
        warn "Chỉ nhập 1, 2 hoặc 3."
        continue
        ;;
    esac
    if [[ "$ACCESS" != "tunnel" && $PORTS_BUSY -eq 1 ]]; then
      warn "Cách này cần cổng 80/443 nhưng chúng đang bị ${PORTS_BUSY_BY:-chương trình khác} dùng. Chọn 1 (Cloudflare Tunnel)."
      continue
    fi
    break
  done
}

ask_gateways() {
  say ""
  info "Gateway ChatGPT / Gemini cho phép agent dùng tài khoản ChatGPT / Gemini (web) thay cho API key (tốn thêm ~250 MB RAM)."
  if ask_yn "Bật gateway ChatGPT / Gemini?" Y; then GATEWAYS=1; else GATEWAYS=0; fi
}

# ------------------------------------------------------------------------------------------------------------------
# Cài gói + Docker
# ------------------------------------------------------------------------------------------------------------------
# DPkg::Lock::Timeout: chờ (tối đa 10 phút) nếu apt đang bận, vd unattended-upgrades vừa chạy trên VPS mới
apt_install() { DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y -q --no-install-recommends "$@"; }

install_base() {
  local need=() p
  for p in git curl ca-certificates openssh-client openssl; do
    dpkg -s "$p" >/dev/null 2>&1 || need+=("$p")
  done
  if [[ ${#need[@]} -gt 0 ]]; then
    info "Cài gói cần thiết: ${need[*]}…"
    run_logged "apt-get update" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 update -q || die "apt-get update lỗi."
    run_logged "apt-get install base" apt_install "${need[@]}" || die "Không cài được: ${need[*]}."
  fi
  ok "Đã có git, curl, ssh, openssl"
}

install_docker() {
  if docker compose version >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || true
    ok "Đã có Docker $(docker --version 2>/dev/null | sed 's/.*version \([^,]*\).*/\1/'), Compose $(docker compose version --short 2>/dev/null)"
    return 0
  fi
  local conflicts=() p url codename
  for p in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
    dpkg -s "$p" >/dev/null 2>&1 && conflicts+=("$p")
  done
  if [[ ${#conflicts[@]} -gt 0 ]]; then
    warn "Máy có gói Docker của hệ điều hành: ${conflicts[*]}. Cần gỡ để cài Docker chính thức (container đang chạy sẽ dừng)."
    ask_yn "Gỡ các gói trên và cài Docker chính thức?" Y || die "Đã huỷ. Gỡ các gói đó bằng tay rồi chạy lại."
    run_logged "apt-get remove conflicts" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 remove -y "${conflicts[@]}" ||
      die "Không gỡ được ${conflicts[*]}."
  fi
  info "Đang cài Docker từ kho apt chính thức của Docker (2-4 phút)…"
  if [[ "$OS_ID" == "ubuntu" ]]; then
    url="https://download.docker.com/linux/ubuntu"
    codename=$(os_field UBUNTU_CODENAME)
    [[ -n "$codename" ]] || codename=$(os_field VERSION_CODENAME)
  else
    url="https://download.docker.com/linux/debian"
    codename=$(os_field VERSION_CODENAME)
  fi
  [[ "$codename" =~ ^[a-z]+$ ]] || die "Không xác định được VERSION_CODENAME trong /etc/os-release."
  install -m 0755 -d /etc/apt/keyrings
  run_logged "docker gpg" curl -fsSL "$url/gpg" -o /etc/apt/keyrings/docker.asc || die "Không tải được khoá GPG của Docker."
  chmod a+r /etc/apt/keyrings/docker.asc
  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: $url
Suites: $codename
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  run_logged "apt-get update (docker)" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 update -q || die "apt-get update lỗi."
  run_logged "apt-get install docker" apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ||
    die "Cài Docker thất bại."
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || die "Đã cài Docker nhưng lệnh docker compose không chạy."
  ok "Đã cài Docker $(docker --version | sed 's/.*version \([^,]*\).*/\1/'), Compose $(docker compose version --short)"
}

# ------------------------------------------------------------------------------------------------------------------
# Deploy key + mã nguồn
# ------------------------------------------------------------------------------------------------------------------
# GitHub SSH: github.com:22, hoặc ssh.github.com:443 khi VPS chặn cổng 22 ra ngoài (cùng khoá máy chủ)
detect_github_ssh() {
  if tcp_ok github.com 22; then
    GH_SSH_HOST=github.com GH_SSH_PORT=22
  elif tcp_ok ssh.github.com 443; then
    GH_SSH_HOST=ssh.github.com GH_SSH_PORT=443
  fi
}

pin_github_host_key() {
  local scan fp spec=$GH_SSH_HOST
  [[ "$GH_SSH_PORT" == "22" ]] || spec="[$GH_SSH_HOST]:$GH_SSH_PORT"
  install -d -m 700 /root/.ssh
  if [[ -s "$KNOWN_HOSTS" ]]; then
    fp=$(ssh-keygen -F "$spec" -f "$KNOWN_HOSTS" 2>/dev/null | grep -v '^#' | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' | head -n 1 || true)
    [[ "$fp" == "$GITHUB_ED25519_FP" ]] && return 0
  fi
  scan=$(ssh-keyscan -p "$GH_SSH_PORT" -t ed25519 "$GH_SSH_HOST" 2>/dev/null | grep -v '^#' || true)
  [[ -n "$scan" ]] || die "Không kết nối được $GH_SSH_HOST:$GH_SSH_PORT (tường lửa chặn kết nối ra ngoài?)."
  fp=$(printf '%s\n' "$scan" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' | head -n 1 || true)
  [[ "$fp" == "$GITHUB_ED25519_FP" ]] ||
    die "Khoá máy chủ GitHub không khớp fingerprint GitHub công bố ($fp). Có thể mạng bị can thiệp - dừng lại."
  printf '%s\n' "$scan" >>"$KNOWN_HOSTS"
  chmod 600 "$KNOWN_HOSTS"
}

# ---- 2 cách lấy mã nguồn: GIT_AUTH = key (Deploy key, SSH) | token (username + token classic, HTTPS)
# Token: chỉ đi qua biến môi trường của tiến trình git (GIT_ASKPASS) và header curl đọc từ file 600 - không bao giờ
# nằm trong URL, argv, .git/config, log hay màn hình. Lưu ở GIT_CRED (root, 600) để `update` dùng lại.
GIT_AUTH="" GH_USER="" GH_TOKEN=""
GIT_CRED_DIR="/etc/ads-agent"
GIT_CRED="$GIT_CRED_DIR/git-auth"

askpass_helper() {
  local h="$TMPD/askpass.sh"
  if [[ ! -x "$h" ]]; then
    cat >"$h" <<'EOF'
#!/bin/sh
case "$1" in
  Username*) printf '%s\n' "$ADS_AGENT_GIT_USER" ;;
  *) printf '%s\n' "$ADS_AGENT_GIT_TOKEN" ;;
esac
EOF
    chmod 700 "$h"
  fi
  printf '%s' "$h"
}
git_https() {
  ADS_AGENT_GIT_USER="$GH_USER" ADS_AGENT_GIT_TOKEN="$GH_TOKEN" GIT_ASKPASS="$(askpass_helper)" \
    GIT_TERMINAL_PROMPT=0 git -c credential.helper= -c core.sshCommand= "$@"
}
git_remote() { if [[ "$GIT_AUTH" == "token" ]]; then git_https "$@"; else git_ssh "$@"; fi; }
repo_url() {
  if [[ "$GIT_AUTH" == "token" ]]; then printf 'https://github.com/%s.git' "$REPO"; else repo_ssh_url; fi
}
repo_reachable() { git_remote ls-remote --heads "$(repo_url)" "$BRANCH" >/dev/null 2>&1; }

ask_git_auth() {
  say ""
  say "   ${C_BLD}Cách lấy mã nguồn từ repo GitHub riêng tư $REPO:${C_RST}"
  say "     1) Deploy key (khuyến nghị) — script tạo khoá chỉ quyền ĐỌC, bạn dán vào repo → Settings → Deploy keys"
  say "     2) Username + token classic GitHub — token (PAT classic) có quyền repo của tài khoản được vào repo"
  local def=1
  if [[ ${GH_SSH_OK:-1} -eq 0 ]]; then
    def=2
    warn "VPS không vào được GitHub qua SSH nên chỉ dùng được cách 2."
  fi
  while :; do
    ask "Chọn 1 hoặc 2" "$def"
    case "$REPLY" in
      1)
        [[ ${GH_SSH_OK:-1} -eq 1 ]] || { warn "Cách 1 cần SSH tới GitHub (đang bị chặn). Chọn 2."; continue; }
        GIT_AUTH=key
        ;;
      2) GIT_AUTH=token ;;
      *)
        warn "Chỉ nhập 1 hoặc 2."
        continue
        ;;
    esac
    break
  done
}

# token_check: 0 = token đọc được repo. Ghi lý do vào TOKEN_PROBLEM.
TOKEN_PROBLEM=""
token_check() {
  local hdr="$TMPD/gh.hdr" out="$TMPD/gh.out" code scopes
  (
    umask 077
    printf 'Authorization: token %s\nAccept: application/vnd.github+json\nUser-Agent: ads-agent-deploy\n' "$GH_TOKEN" >"$hdr"
  )
  code=$(curl -sS -o "$out" -D "$TMPD/gh.head" -w '%{http_code}' --max-time 15 -H @"$hdr" "https://api.github.com/repos/$REPO" 2>/dev/null || true)
  rm -f "$hdr"
  scopes=$(sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: *//p' "$TMPD/gh.head" 2>/dev/null | tr -d '\r' || true)
  case "$code" in
    200)
      if [[ -n "$scopes" && ! " ${scopes//,/ } " =~ [[:space:]]repo[[:space:]] ]]; then
        TOKEN_PROBLEM="token thiếu quyền repo (đang có: $scopes)"
        return 1
      fi
      return 0
      ;;
    401) TOKEN_PROBLEM="token sai, đã bị thu hồi hoặc hết hạn (GitHub trả 401)" ;;
    403) TOKEN_PROBLEM="token bị từ chối (403): thiếu quyền repo, hoặc tổ chức chặn token classic (SSO chưa authorize)" ;;
    404) TOKEN_PROBLEM="tài khoản $GH_USER không thấy repo $REPO (404): chưa được mời vào repo hoặc token thiếu quyền repo" ;;
    *) TOKEN_PROBLEM="không gọi được GitHub API (mã ${code:-?}), kiểm tra mạng" ;;
  esac
  return 1
}

load_token() {
  GH_USER=$(env_get GIT_USER "$GIT_CRED")
  GH_TOKEN=$(env_get GIT_TOKEN "$GIT_CRED")
}
save_token() {
  install -d -m 700 "$GIT_CRED_DIR"
  [[ -f "$GIT_CRED" ]] || (umask 077 && : >"$GIT_CRED")
  env_set GIT_USER "$GH_USER" "$GIT_CRED"
  env_set GIT_TOKEN "$GH_TOKEN" "$GIT_CRED"
  chmod 600 "$GIT_CRED"
}

setup_token() {
  say ""
  say "   ${C_BLD}Tạo token classic (nếu chưa có):${C_RST}"
  say "     GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic) → Generate new token"
  say "     Tick quyền ${C_BLD}repo${C_RST} → Generate → copy token (bắt đầu bằng ghp_). Tài khoản phải được vào repo $REPO."
  load_token
  if [[ -n "$GH_TOKEN" ]] && token_check && ask_yn "Đã có token đang hoạt động cho tài khoản $GH_USER. Dùng lại?" Y; then
    ok "Dùng token đã lưu của $GH_USER"
    return 0
  fi
  while :; do
    ask "Username GitHub" "$GH_USER"
    GH_USER=$(printf '%s' "$REPLY" | tr -d '[:space:]')
    [[ "$GH_USER" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$ ]] || { warn "Username không hợp lệ."; continue; }
    ask_secret "Token classic (ẩn khi gõ)"
    GH_TOKEN=$(printf '%s' "$REPLY" | tr -d '[:space:]')
    REPLY=""
    [[ -n "$GH_TOKEN" ]] || { warn "Chưa nhập token."; continue; }
    if token_check && repo_reachable; then
      save_token
      ok "Token hoạt động: tài khoản $GH_USER đọc được repo $REPO (lưu ở $GIT_CRED, chỉ root đọc được)"
      return 0
    fi
    warn "Không dùng được token: ${TOKEN_PROBLEM:-git không đọc được repo}. Nhập lại."
  done
}

setup_source_auth() {
  if [[ "$GIT_AUTH" == "token" ]]; then setup_token; else setup_deploy_key; fi
}

setup_deploy_key() {
  pin_github_host_key
  if [[ ! -f "$KEY" ]]; then
    ssh-keygen -q -t ed25519 -N "" -C "ads-agent-deploy@$(hostname -s 2>/dev/null || echo vps)" -f "$KEY"
    chmod 600 "$KEY"
  fi
  if repo_reachable; then
    ok "Deploy key đã có quyền đọc repo $REPO"
    return 0
  fi
  say ""
  say "   ${C_BLD}Thêm Deploy key vào GitHub (chỉ quyền ĐỌC):${C_RST}"
  say "     1. Mở: ${C_BLU}https://github.com/$REPO/settings/keys/new${C_RST}"
  say "     2. Title: Ads Agent VPS $(hostname -s 2>/dev/null || true)"
  say "     3. Key: dán NGUYÊN dòng dưới đây (bắt đầu bằng ssh-ed25519)"
  say "     4. KHÔNG tick \"Allow write access\" → bấm Add key"
  say ""
  printf '%s%s%s\n\n' "$C_GRN$C_BLD" "$(cat "$KEY.pub")" "$C_RST"
  log "   (đã in public key Deploy key: $(ssh-keygen -lf "$KEY.pub" | awk '{print $2}'))"
  while :; do
    local ans=""
    read -r -p "   Đã thêm Deploy key xong? Gõ Y rồi Enter để tiếp tục (Q để thoát): " ans </dev/tty || tty_closed
    case "$ans" in
      [Yy]*)
        if repo_reachable; then
          ok "Deploy key hoạt động: đọc được repo $REPO (nhánh $BRANCH)"
          return 0
        fi
        warn "Chưa đọc được repo. Kiểm tra: đúng repo $REPO, dán đủ cả dòng key, đã bấm Add key. GitHub có thể mất vài giây."
        ;;
      [Qq]*) die "Đã thoát. Chạy lại script khi đã thêm Deploy key (key vẫn giữ nguyên: $KEY.pub)." ;;
      *) info "Gõ Y rồi Enter khi đã thêm key, hoặc Q để thoát." ;;
    esac
  done
}

set_repo_remote() {
  if [[ "$GIT_AUTH" == "token" ]]; then
    git -C "$DIR" config --unset core.sshCommand >/dev/null 2>&1 || true
  else
    git -C "$DIR" config core.sshCommand "$GIT_SSH"
  fi
  git -C "$DIR" remote set-url origin "$(repo_url)"
}

fetch_source() {
  if [[ -d "$DIR/.git" ]]; then
    set_repo_remote
    run_logged "git fetch" git_remote -C "$DIR" fetch --prune origin "$BRANCH" ||
      die "git fetch thất bại (Deploy key bị gỡ hoặc token hết hạn?). Chạy lại: sudo ads-agent-deploy update"
    if ! run_logged "git merge --ff-only" git -C "$DIR" merge --ff-only "origin/$BRANCH"; then
      die "Thư mục $DIR có thay đổi cục bộ nên không cập nhật được. Xem: cd $DIR && git status"
    fi
    ok "Mã nguồn đã cập nhật: $(git -C "$DIR" log -1 --format='%h %s' | cut -c1-80)"
  elif [[ -e "$DIR" && -n "$(ls -A "$DIR" 2>/dev/null)" ]]; then
    die "Thư mục $DIR đã có dữ liệu nhưng không phải bản cài từ git. Đổi thư mục: sudo ADS_AGENT_DIR=/opt/ads-agent-2 bash $0"
  else
    install -d -m 755 "$(dirname "$DIR")"
    run_logged "git clone" git_remote clone --branch "$BRANCH" --single-branch "$(repo_url)" "$DIR" ||
      die "git clone thất bại."
    set_repo_remote
    ok "Đã tải mã nguồn vào $DIR ($(git -C "$DIR" log -1 --format='%h' ))"
  fi
}

pkg_version() { sed -n 's/^  "version": "\([0-9][0-9.]*\)",*$/\1/p' "$DIR/package.json" | head -n 1; }

# ------------------------------------------------------------------------------------------------------------------
# Cách truy cập Internet
# ------------------------------------------------------------------------------------------------------------------
public_ip() {
  local ip=""
  ip=$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || curl -4fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && printf '%s' "$ip"
}

collect_tunnel_token() {
  say ""
  say "   ${C_BLD}Tạo Cloudflare Tunnel (làm trên trình duyệt):${C_RST}"
  say "     1. Cloudflare → Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared → đặt tên (vd ads-agent)"
  say "     2. Ở bước cài connector chọn Docker, copy đoạn token dài sau chữ --token (bắt đầu bằng eyJ)"
  say "     3. Public hostname: $DOMAIN  →  Service: HTTP  ·  URL: caddy:80"
  info "Không cần mở cổng 80/443 và không cần bản ghi A: Cloudflare tự tạo bản ghi DNS cho tunnel."
  local cur
  cur=$(env_get TUNNEL_TOKEN)
  if [[ -n "$cur" ]] && ask_yn "Đã có token tunnel trong .env. Giữ token cũ?" Y; then
    TUNNEL_TOKEN_VALUE=$cur
    return 0
  fi
  while :; do
    ask_secret "Dán token tunnel, hoặc cả câu lệnh Cloudflare hiện ra (ẩn khi gõ)"
    # nhận cả `... run --token eyJ…` lẫn `cloudflared service install eyJ…`: chỉ lấy phần token eyJ…
    local t=""
    [[ "$REPLY" =~ (eyJ[A-Za-z0-9_=-]{40,}) ]] && t=${BASH_REMATCH[1]}
    REPLY=""
    if [[ -n "$t" ]]; then
      TUNNEL_TOKEN_VALUE=$t
      ok "Đã nhận token tunnel (${#t} ký tự)"
      return 0
    fi
    warn "Token không đúng dạng (phải bắt đầu bằng eyJ, dài). Dán lại đúng phần sau --token."
  done
}

collect_origin_cert() {
  local certs="$DIR/deploy/caddy/certs"
  say ""
  say "   ${C_BLD}Chuẩn bị trên Cloudflare (làm trên trình duyệt):${C_RST}"
  say "     1. DNS: bản ghi A  $DOMAIN  →  IP VPS${PUBLIC_IP:+ ($PUBLIC_IP)}, BẬT proxy (mây cam)"
  say "     2. SSL/TLS → Overview: chọn Full (strict)"
  say "     3. SSL/TLS → Origin Server → Create Certificate (giữ mặc định, hostname có $DOMAIN) → Create"
  if [[ -s "$certs/origin.pem" && -s "$certs/origin.key" ]] && ask_yn "Đã có Origin Certificate trên máy. Giữ chứng chỉ cũ?" Y; then
    return 0
  fi
  while :; do
    say ""
    info "Dán ${C_BLD}Origin Certificate${C_RST} (từ -----BEGIN CERTIFICATE----- đến -----END CERTIFICATE-----) rồi Enter:"
    read_pem '^-----BEGIN CERTIFICATE-----' '^-----END CERTIFICATE-----'
    CERT_PEM=$REPLY
    info "Dán ${C_BLD}Private Key${C_RST} (từ -----BEGIN PRIVATE KEY----- đến -----END PRIVATE KEY-----) rồi Enter:"
    read_pem '^-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' '^-----END ([A-Z]+ )?PRIVATE KEY-----'
    KEY_PEM=$REPLY
    printf '%s' "$CERT_PEM" >"$TMPD/origin.pem"
    (
      umask 077
      printf '%s' "$KEY_PEM" >"$TMPD/origin.key"
    )
    if ! openssl x509 -in "$TMPD/origin.pem" -noout 2>/dev/null; then
      warn "Origin Certificate không đọc được. Dán lại."
      continue
    fi
    if ! openssl pkey -in "$TMPD/origin.key" -noout 2>/dev/null; then
      warn "Private key không đọc được. Dán lại."
      continue
    fi
    if [[ "$(openssl x509 -in "$TMPD/origin.pem" -noout -pubkey 2>/dev/null | openssl sha256)" != \
      "$(openssl pkey -in "$TMPD/origin.key" -pubout 2>/dev/null | openssl sha256)" ]]; then
      warn "Private key không khớp với Origin Certificate (dán nhầm cặp?). Dán lại cả hai."
      continue
    fi
    local san apex=${DOMAIN#*.}
    san=$(openssl x509 -in "$TMPD/origin.pem" -noout -ext subjectAltName 2>/dev/null | tr ',' '\n' | sed -n 's/.*DNS://p' || true)
    if ! printf '%s\n' "$san" | grep -qxF -e "$DOMAIN" -e "*.$apex"; then
      warn "Chứng chỉ không có tên $DOMAIN (có: $(printf '%s' "$san" | tr '\n' ' ')). Tạo lại chứng chỉ có hostname đúng."
      ask_yn "Vẫn dùng chứng chỉ này?" N || continue
    fi
    install -d -m 755 "$certs"
    install -m 644 "$TMPD/origin.pem" "$certs/origin.pem"
    install -m 600 "$TMPD/origin.key" "$certs/origin.key"
    rm -f "$TMPD/origin.key"
    KEY_PEM=""
    ok "Đã lưu Origin Certificate vào $certs (khoá riêng quyền 600, không vào git)"
    return 0
  done
}

check_dns_direct() {
  local resolved
  resolved=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)
  if [[ -z "$PUBLIC_IP" ]]; then
    warn "Không xác định được IP công khai của VPS; bỏ qua kiểm tra DNS."
  elif [[ " $resolved " == *" $PUBLIC_IP "* ]]; then
    ok "DNS: $DOMAIN → $PUBLIC_IP (đúng IP VPS)"
  else
    warn "DNS: $DOMAIN đang trỏ về ${resolved:-<chưa có bản ghi>}, chưa phải IP VPS $PUBLIC_IP."
    info "Tạo bản ghi A: $DOMAIN → $PUBLIC_IP (nếu dùng Cloudflare thì để mây XÁM / DNS only)."
    info "SSL chỉ cấp được khi DNS trỏ đúng; hệ thống tự thử lại sau khi bạn sửa DNS."
    ask_yn "Vẫn tiếp tục?" Y || die "Đã dừng. Sửa DNS rồi chạy lại."
  fi
}

open_firewall() {
  [[ "$ACCESS" == "tunnel" ]] && return 0
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 80/tcp >/dev/null && ufw allow 443/tcp >/dev/null && ufw allow 443/udp >/dev/null
    ok "Tường lửa UFW: đã mở 80/tcp, 443/tcp, 443/udp"
  else
    info "Nhớ mở cổng 80 và 443 ở tường lửa của nhà cung cấp VPS (security group) nếu có."
  fi
}

apply_access_env() {
  # cùng giá trị với SSL_PRESETS của scripts/gen-env.mjs (cách 1 = tunnel, 2 = auto, 3 = cloudflare)
  local site="" http="80" https="443" cf=0 clientip=direct tls=auto
  case "$ACCESS" in
    tunnel) site="http://" http="127.0.0.1:" https="127.0.0.1:" cf=1 clientip=tunnel tls=tunnel ;;
    cloudflare) clientip=cloudflare tls=cloudflare-origin ;;
  esac
  env_set APP_DOMAIN "$DOMAIN"
  env_set BETTER_AUTH_URL "https://$DOMAIN"
  env_set ACME_EMAIL "$EMAIL"
  env_set CADDY_REPLICAS 1
  env_set CADDY_CLIENT_IP "$clientip"
  env_set CADDY_TLS "$tls"
  env_set WEB_HOST_PORT ""
  env_set CADDY_SITE_SCHEME "$site"
  env_set CADDY_HTTP_PORT_BIND "$http"
  env_set CADDY_HTTPS_PORT_BIND "$https"
  env_set CLOUDFLARED_REPLICAS "$cf"
  if [[ "$ACCESS" == "tunnel" ]]; then env_set TUNNEL_TOKEN "$TUNNEL_TOKEN_VALUE"; fi
  TUNNEL_TOKEN_VALUE=""
}

# ------------------------------------------------------------------------------------------------------------------
# .env, build, chạy
# ------------------------------------------------------------------------------------------------------------------
create_env() {
  if [[ -f "$DIR/.env" ]]; then
    ok "Giữ nguyên .env đã có (secret và khoá mã hoá không đổi)"
    return 0
  fi
  local args=(--domain "$DOMAIN" --email "$EMAIL" --ssl "$ACCESS" --no-updater)
  [[ $GATEWAYS -eq 1 ]] || args+=(--no-gateway)
  (cd "$DIR" && export HOST_PROJECT_DIR="$DIR" && run_logged "gen-secrets" sh scripts/gen-secrets.sh "${args[@]}") ||
    die "Không tạo được .env."
  [[ -s "$DIR/.env" ]] || die "Không thấy $DIR/.env sau khi sinh."
  chmod 600 "$DIR/.env"
  ok "Đã tạo $DIR/.env (quyền 600, secret ngẫu nhiên)"
  warn "Sao lưu riêng file $DIR/.env (nhất là ENCRYPTION_KEYS): mất nó thì không giải mã được kết nối đã lưu."
}

build_and_start() {
  local ver
  ver=$(pkg_version)
  [[ -n "$ver" ]] || die "Không đọc được phiên bản trong $DIR/package.json."
  env_set APP_VERSION "$ver"
  # image tự build không có chữ ký phát hành: tắt updater (cập nhật bằng `sudo ads-agent-deploy update`)
  env_set COMPOSE_PROFILES ""
  info "Đang build 3 image từ mã nguồn (lần đầu 5-15 phút, tuỳ cấu hình VPS)…"
  local t0=$SECONDS
  (export APP_BUILD_VERSION="$ver" && run_logged "docker compose build" dc_build build) ||
    die "Build image thất bại. Thiếu RAM/ổ đĩa? Xem nhật ký: $LOG"
  ok "Build xong v$ver trong $(((SECONDS - t0) / 60)) phút"
  info "Đang khởi động (database → migrate → web, worker, gateway, Caddy)…"
  run_logged "docker compose up" dc_build up -d --no-build --remove-orphans || die "docker compose up thất bại."
}

wait_healthy() {
  local i code=""
  for ((i = 0; i < 90; i++)); do
    code=$(cd "$DIR" && docker compose ps -a migrate --format '{{.State}} {{.ExitCode}}' 2>/dev/null | head -n 1 || true)
    if [[ "$code" == "exited "[1-9]* ]]; then
      (cd "$DIR" && docker compose logs --tail 30 migrate) >&2 || true
      die "Bước migrate database lỗi (xem log ở trên)."
    fi
    if (cd "$DIR" && docker compose exec -T web node -e \
      "fetch('http://127.0.0.1:3000/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))") >/dev/null 2>&1; then
      ok "Web đã chạy, database kết nối tốt"
      return 0
    fi
    sleep 4
  done
  (cd "$DIR" && docker compose ps) >&2 || true
  die "Web chưa sẵn sàng sau 6 phút. Xem: cd $DIR && docker compose logs --tail 50 web"
}

check_public() {
  local url="https://$DOMAIN/api/health" i
  for ((i = 0; i < 12; i++)); do
    if curl -fsS --max-time 10 "$url" >/dev/null 2>&1; then
      ok "Truy cập được từ Internet: https://$DOMAIN"
      return 0
    fi
    sleep 5
  done
  case "$ACCESS" in
    tunnel) warn "Chưa vào được https://$DOMAIN. Kiểm tra Public hostname của tunnel: $DOMAIN → HTTP · caddy:80." ;;
    auto) warn "Chưa vào được https://$DOMAIN. Thường do DNS chưa trỏ đúng IP hoặc cổng 80/443 bị chặn; SSL tự cấp khi sửa xong." ;;
    cloudflare) warn "Chưa vào được https://$DOMAIN. Kiểm tra: mây cam, SSL/TLS = Full (strict), cổng 443 mở từ Cloudflare." ;;
  esac
}

install_commands() {
  install -m 755 "$DIR/scripts/deploy-vps.sh" "$SELF_BIN"
  install -m 755 "$DIR/scripts/ads-agent" "$HELPER_BIN"
  touch "$CONF"
  chmod 644 "$CONF"
  env_set ADS_AGENT_DIR "$DIR" "$CONF"
  env_set ADS_AGENT_SOURCE_BUILD 1 "$CONF"
  env_set ADS_AGENT_GIT_AUTH "${GIT_AUTH:-key}" "$CONF"
  chmod 644 "$CONF"
  ok "Đã cài lệnh: sudo ads-agent-deploy (cập nhật / đổi cách truy cập), sudo ads-agent (trạng thái, log, sao lưu…)"
}

prune_images() {
  docker image prune -f >/dev/null 2>&1 || true
  docker builder prune -f --filter until=168h >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------------------------------------------
# Lệnh
# ------------------------------------------------------------------------------------------------------------------
final_screen() {
  local token
  token=$(env_get SETUP_TOKEN)
  say ""
  printf '%s══════════════════════════════════════════════════════════════════%s\n' "$C_GRN$C_BLD" "$C_RST"
  printf '%s  Ads Agent đã chạy!%s\n' "$C_GRN$C_BLD" "$C_RST"
  printf '%s══════════════════════════════════════════════════════════════════%s\n' "$C_GRN$C_BLD" "$C_RST"
  printf '  1. Mở:              %shttps://%s/setup%s\n' "$C_BLD" "$DOMAIN" "$C_RST"
  printf '  2. Mã thiết lập:    %s%s%s\n' "$C_YLW$C_BLD" "${token:-<xem bằng: sudo ads-agent-deploy setup-key>}" "$C_RST"
  printf '     (dán vào ô "Mã thiết lập (SETUP_TOKEN)", tạo quản trị viên rồi bật xác thực 2 bước)\n'
  printf '  3. Làm theo trình hướng dẫn: kết nối Ads MCP → lõi AI → Telegram → đội mặc định.\n\n'
  printf '  Cập nhật bản mới:   sudo ads-agent-deploy update\n'
  printf '  Đổi cách truy cập:  sudo ads-agent-deploy reconfigure\n'
  printf '  Trạng thái / log:   sudo ads-agent status · sudo ads-agent logs web\n'
  printf '  Sao lưu:            sudo ads-agent backup   (nhớ sao lưu riêng %s/.env)\n' "$DIR"
  printf '  Không gửi mã thiết lập qua chat/email. Nhật ký cài đặt: %s\n\n' "$LOG"
  log "Hoàn tất cài đặt cho $DOMAIN (mã thiết lập chỉ in ra màn hình)"
}

cmd_install() {
  STEP_TOTAL=10
  precheck
  step "Thông tin triển khai"
  ask_domain_email
  ask_access
  ask_gateways
  ask_git_auth
  step "Gói hệ thống, Docker, swap"
  install_base
  install_docker
  ensure_swap
  step "Quyền đọc mã nguồn trên GitHub"
  setup_source_auth
  step "Tải mã nguồn"
  fetch_source
  step "Cách truy cập Internet"
  PUBLIC_IP=$(public_ip || true)
  [[ -n "$PUBLIC_IP" ]] && ok "IP công khai của VPS: $PUBLIC_IP"
  case "$ACCESS" in
    tunnel) collect_tunnel_token ;;
    auto) check_dns_direct ;;
    cloudflare) collect_origin_cert ;;
  esac
  open_firewall
  step "Cấu hình (.env)"
  create_env
  apply_access_env
  ok "Cách truy cập: $(access_label)"
  step "Build và khởi động"
  build_and_start
  step "Kiểm tra sức khoẻ"
  wait_healthy
  check_public
  step "Hoàn tất"
  install_commands
  prune_images
  final_screen
}

access_label() {
  case "${ACCESS:-$(current_access)}" in
    tunnel) printf 'Cloudflare Tunnel' ;;
    cloudflare) printf 'Proxy Cloudflare + Origin Certificate' ;;
    *) printf 'Trỏ IP về VPS + SSL tự động (Let'"'"'s Encrypt)' ;;
  esac
}
current_access() {
  case "$(env_get CADDY_TLS)" in
    tunnel) printf tunnel ;;
    cloudflare-origin | cloudflare-origin-aop) printf cloudflare ;;
    *) printf auto ;;
  esac
}

cmd_update() {
  STEP_TOTAL=4
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Cần quyền root. Chạy lại: sudo ads-agent-deploy update"
  [[ -f "$DIR/.env" && -d "$DIR/.git" ]] || die "Chưa có bản cài ở $DIR. Chạy: sudo bash deploy-vps.sh"
  : >>"$LOG" 2>/dev/null || LOG=/dev/null
  DOMAIN=$(env_get APP_DOMAIN)
  ACCESS=$(current_access)
  step "Sao lưu database trước khi cập nhật"
  if (cd "$DIR" && docker compose ps --status running --services 2>/dev/null | grep -qx backup); then
    # shellcheck disable=SC2016
    if (cd "$DIR" && docker compose exec -T backup sh -c 'pg_dump -Fc -Z zstd:6 -f /backups/adsagent_preupdate_$(date +%F_%H%M%S).dump') >>"$LOG" 2>&1; then
      ok "Đã sao lưu database vào $DIR/backups/"
    else
      warn "Không sao lưu được database (dịch vụ backup lỗi?)."
      ask_yn "Vẫn cập nhật?" N || die "Đã huỷ cập nhật."
    fi
  else
    warn "Dịch vụ backup không chạy: bỏ qua sao lưu."
  fi
  step "Tải mã mới nhất"
  GIT_AUTH=$(env_get ADS_AGENT_GIT_AUTH "$CONF")
  [[ -n "$GIT_AUTH" ]] || GIT_AUTH=key
  if [[ "$GIT_AUTH" == "token" ]]; then
    load_token
    if ! token_check; then
      warn "Token GitHub đã lưu không dùng được: ${TOKEN_PROBLEM}."
      setup_token
    fi
  else
    detect_github_ssh
    pin_github_host_key
  fi
  local before after
  before=$(git -C "$DIR" rev-parse --short HEAD)
  fetch_source
  after=$(git -C "$DIR" rev-parse --short HEAD)
  if [[ "$before" == "$after" ]] && ! ask_yn "Không có mã mới ($after). Vẫn build lại và khởi động lại?" N; then
    ok "Không có gì thay đổi."
    exit 0
  fi
  step "Build và khởi động lại"
  build_and_start
  step "Kiểm tra sức khoẻ"
  wait_healthy
  install_commands
  prune_images
  say ""
  ok "Đã cập nhật lên v$(pkg_version) ($after). Địa chỉ: https://$DOMAIN"
}

cmd_reconfigure() {
  STEP_TOTAL=4
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Cần quyền root. Chạy lại: sudo ads-agent-deploy reconfigure"
  [[ -f "$DIR/.env" ]] || die "Chưa có bản cài ở $DIR. Chạy: sudo bash deploy-vps.sh"
  : >>"$LOG" 2>/dev/null || LOG=/dev/null
  step "Cách truy cập mới"
  info "Hiện tại: $(ACCESS="" access_label) · tên miền $(env_get APP_DOMAIN)"
  if ss -ltnH '( sport = :80 or sport = :443 )' 2>/dev/null | grep -q .; then
    # cổng có thể đang do chính Caddy của Ads Agent giữ: chỉ coi là bận khi không phải container caddy của mình
    if ! (cd "$DIR" && docker compose ps --status running --services 2>/dev/null | grep -qx caddy); then PORTS_BUSY=1; fi
  fi
  ask_domain_email
  ask_access
  step "Thông tin cho cách truy cập"
  PUBLIC_IP=$(public_ip || true)
  case "$ACCESS" in
    tunnel) collect_tunnel_token ;;
    auto) check_dns_direct ;;
    cloudflare) collect_origin_cert ;;
  esac
  open_firewall
  apply_access_env
  step "Áp dụng"
  run_logged "docker compose up (reconfigure)" dc_build up -d --no-build --remove-orphans || die "docker compose up thất bại."
  (cd "$DIR" && docker compose restart caddy) >>"$LOG" 2>&1 || true
  step "Kiểm tra"
  wait_healthy
  check_public
  ok "Đã chuyển sang: $(access_label)"
}

cmd_setup_key() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Cần quyền root: sudo ads-agent-deploy setup-key"
  local t
  t=$(env_get SETUP_TOKEN)
  [[ -n "$t" ]] || die "Không thấy SETUP_TOKEN trong $DIR/.env."
  printf 'Mở https://%s/setup và dán mã thiết lập: %s%s%s\n' "$(env_get APP_DOMAIN)" "$C_YLW$C_BLD" "$t" "$C_RST"
  printf 'Trang /setup tự khoá sau khi đã có tài khoản đầu tiên.\n'
}

cmd_help() {
  cat <<'EOF'
Ads Agent by: noti.vn - triển khai nhanh lên VPS (Deploy key hoặc token GitHub, build trên VPS)
  curl -fsSL https://raw.githubusercontent.com/notivn/ads-agent-simple-install/main/deploy.sh | sudo bash
  sudo bash deploy-vps.sh              cài mới; máy đã cài thì hỏi: cập nhật / đổi cách truy cập
  sudo ads-agent-deploy update         kéo mã mới nhất + build lại + khởi động lại (dữ liệu giữ nguyên)
  sudo ads-agent-deploy reconfigure    đổi cách đưa web ra Internet (Tunnel / trỏ IP / proxy Cloudflare)
  sudo ads-agent-deploy setup-key      in lại mã thiết lập để tạo quản trị viên đầu tiên
Biến tuỳ chọn: ADS_AGENT_REPO (mặc định notivn/Ads-Agent-Simple), ADS_AGENT_BRANCH (main), ADS_AGENT_DIR (/opt/ads-agent)
EOF
}

main() {
  local cmd=${1:-}
  TMPD=$(mktemp -d)
  case "$cmd" in
    "" | install)
      if [[ -f "$DIR/.env" && -d "$DIR/.git" ]]; then
        printf '%sAds Agent đã được cài ở %s (tên miền %s).%s\n' "$C_BLD" "$DIR" "$(env_get APP_DOMAIN)" "$C_RST"
        printf '   1) Cập nhật lên mã mới nhất\n   2) Đổi cách truy cập Internet\n   3) Thoát\n'
        tty_ok || die "Cần chạy trong terminal."
        ask "Chọn" "1"
        case "$REPLY" in
          1) cmd_update ;;
          2) cmd_reconfigure ;;
          *) exit 0 ;;
        esac
      else
        printf '%sAds Agent by: noti.vn — triển khai nhanh lên VPS%s\n' "$C_BLD" "$C_RST"
        cmd_install
      fi
      ;;
    update) cmd_update ;;
    reconfigure) cmd_reconfigure ;;
    setup-key) cmd_setup_key ;;
    help | -h | --help) cmd_help ;;
    *) die "Lệnh không hợp lệ: $cmd. Xem: sudo bash $0 help" ;;
  esac
}

main "$@"
