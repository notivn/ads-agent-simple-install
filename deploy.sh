#!/usr/bin/env bash
# Ads Agent by: noti.vn - triển khai nhanh lên VPS từ repo GitHub riêng tư (build image ngay trên VPS).
#
#   curl -fsSL https://raw.githubusercontent.com/notivn/ads-agent-simple-install/main/deploy.sh | sudo bash
#                                        # 1 dòng: dán vào terminal VPS là chạy (file công khai, không chứa bí mật)
#   sudo bash deploy-vps.sh              # hoặc chạy file đã có trên máy: cài mới; đã cài thì hỏi cập nhật / đổi cách truy cập
#   sudo ads-agent-deploy update         # kéo mã mới nhất + build lại + khởi động lại (dữ liệu giữ nguyên)
#   sudo ads-agent-deploy reconfigure    # đổi cách đưa web ra Internet (Tunnel / trỏ IP / proxy Cloudflare)
#   sudo ads-agent-deploy token          # đổi username / token GitHub (token hết hạn, đổi tài khoản)
#   sudo ads-agent-deploy setup-key      # in lại mã thiết lập (SETUP_TOKEN) để tạo quản trị viên đầu tiên
# Sau lần cài đầu, script được chép thành lệnh `sudo ads-agent-deploy <lệnh>`.
#
# Các bước: bảng kiểm tra máy (root, OS, RAM/ổ đĩa, mạng GitHub/Docker Hub, Docker, cổng 80/443, đồng hồ, tường lửa,
# Ads MCP) → hỏi tên miền + cách truy cập → cài Docker → username + token classic GitHub (quyền repo, gõ ẩn, kiểm
# bằng API) → tải mã nguồn → tạo .env (secret ngẫu nhiên + username/token/nguồn cập nhật) → chứng chỉ / token theo
# cách truy cập → build 2 image (app, updater) → chạy → kiểm tra sức khoẻ → in địa chỉ /setup và mã thiết
# lập. Bản công khai deploy.sh ở repo notivn/ads-agent-simple-install là bản chép NGUYÊN file này (nguồn duy nhất:
# scripts/deploy-vps.sh của repo chính).
# Cập nhật bằng nút trên web (.claude/docs/14-update-system.md §9): .env có UPDATE_GITHUB_USER, UPDATE_GITHUB_TOKEN,
# UPDATE_REPO, UPDATE_SOURCE=branch, UPDATE_BRANCH và COMPOSE_PROFILES=updater (+ dịch vụ AI tuỳ chọn đang bật:
# claude / codex / chatgpt / gemini, luôn được giữ - sudo ads-agent ai enable). Bản mới = "version" trong package.json
# ở đầu nhánh (tăng version + push là phát hành cho mọi VPS). Worker dùng token để kiểm tra bản mới, updater dùng nó
# để git fetch rồi build image ngay trên VPS; container web không bao giờ nhận token.
# 3 cách truy cập Internet (.claude/docs/13-deployment.md §3):
#   1 Cloudflare Tunnel  - không mở cổng, dán token tunnel (dùng được cả khi VPS đang chạy Ads MCP Simple)
#   2 Trỏ IP về VPS      - bản ghi A → IP VPS, hệ thống tự xin chứng chỉ SSL Let's Encrypt (cần cổng 80/443 trống)
#   3 Proxy Cloudflare   - bản ghi A mây cam, dán Origin Certificate + Private key của Cloudflare (SSL Full strict)
# Bí mật (token GitHub, token tunnel, khoá riêng Origin, nội dung .env) không bao giờ in ra màn hình, ghi log hay
# nằm trong tham số lệnh / URL / .git/config. Token GitHub chỉ nằm trong .env (quyền 600, chỉ root đọc được), đi tới
# git qua GIT_ASKPASS (biến môi trường) và tới curl qua header đọc từ file 600. Log: /var/log/ads-agent-deploy.log.
# Không đụng tới Ads MCP Simple: thư mục, mạng, volume, Caddyfile, docker login của nó đều giữ nguyên.
# Bản cài cũ (Deploy key, hoặc token ở /etc/ads-agent/git-auth): `update` / `reconfigure` tự chuyển sang token trong
# .env + remote HTTPS, rồi gỡ Deploy key cũ trên máy.

set -Eeuo pipefail

REPO="${ADS_AGENT_REPO:-}"
BRANCH="${ADS_AGENT_BRANCH:-}"
DEFAULT_REPO="notivn/Ads-Agent-Simple"
DEFAULT_BRANCH="main"
DIR="${ADS_AGENT_DIR:-/opt/ads-agent}"
LOG="/var/log/ads-agent-deploy.log"
CONF="/etc/ads-agent.conf"
SELF_BIN="/usr/local/bin/ads-agent-deploy"
HELPER_BIN="/usr/local/bin/ads-agent"
# thư mục docker login riêng mà service updater mount (chỉ đọc); bản build từ mã nguồn không cần đăng nhập GHCR
UPDATER_DOCKER_DIR="/root/.docker-ads-agent"
# dấu vết của các bản cài cũ (chỉ để chuyển đổi rồi gỡ): Deploy key SSH và file token riêng
LEGACY_KEY="/root/.ssh/ads_agent_deploy_ed25519"
LEGACY_KNOWN_HOSTS="/root/.ssh/known_hosts_ads_agent"
LEGACY_GIT_CRED_DIR="/etc/ads-agent"
LEGACY_GIT_CRED="$LEGACY_GIT_CRED_DIR/git-auth"
MIN_MEM_MB=4096 # RAM + swap tối thiểu để build image Next.js trên VPS

DOMAIN="" EMAIL="" ACCESS="" TUNNEL_TOKEN_VALUE="" CERT_PEM="" KEY_PEM="" PUBLIC_IP=""
PORTS_BUSY=0 PORTS_BUSY_BY="" OS_ID="" TMPD="" TG_BLOCKED=0 TG_PROXY="" TG_PROXY_SET=0

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
UPDATER_STOPPED=0
cleanup() {
  [[ -n "$TMPD" && -d "$TMPD" ]] && rm -rf "$TMPD"
  # cmd_update tạm dừng updater: bật lại kể cả khi dừng giữa chừng
  if [[ $UPDATER_STOPPED -eq 1 ]]; then (cd "$DIR" && docker compose start updater) >/dev/null 2>&1 || true; fi
  return 0
}
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

# COMPOSE_PROFILES with "updater" first + every other profile of .env kept (v0.6.0: the AI services claude / codex /
# chatgpt / gemini enabled with `sudo ads-agent ai enable` must survive update / reconfigure / token - 20 §8), deduplicated
profiles_with_updater() {
  local p out="updater" seen=",updater,"
  local -a arr=()
  IFS=',' read -r -a arr <<<"$(env_get COMPOSE_PROFILES)"
  for p in "${arr[@]}"; do
    p=${p//[[:space:]]/}
    [[ -n "$p" && "$p" =~ ^[A-Za-z0-9_.-]+$ && "$seen" != *",$p,"* ]] || continue
    seen+="$p,"
    out+=",$p"
  done
  printf '%s' "$out"
}

# COMPOSE_PROFILES of the source build: updater + the enabled AI profiles whose service docker-compose.yml (of the
# code just fetched) defines - their image (${APP_IMAGE}-gateway, from gateway/) is built with the app; nothing else.
build_profiles() {
  local name out="updater"
  local -a arr=()
  IFS=',' read -r -a arr <<<"$(env_get COMPOSE_PROFILES)"
  for name in claude codex chatgpt gemini; do
    [[ " ${arr[*]//[[:space:]]/} " == *" $name "* ]] || continue
    grep -qE "^  ai-$name:[[:space:]]*(#.*)?$" "$DIR/docker-compose.yml" 2>/dev/null || continue
    out+=",$name"
  done
  printf '%s' "$out"
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

# repo / nhánh: biến môi trường ADS_AGENT_REPO / ADS_AGENT_BRANCH > UPDATE_REPO / UPDATE_BRANCH của .env > mặc định
resolve_source() {
  [[ -n "$REPO" ]] || REPO=$(env_get UPDATE_REPO)
  [[ -n "$REPO" ]] || REPO=$DEFAULT_REPO
  [[ -n "$BRANCH" ]] || BRANCH=$(env_get UPDATE_BRANCH)
  [[ -n "$BRANCH" ]] || BRANCH=$DEFAULT_BRANCH
  [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "Tên repo không hợp lệ: $REPO (cần dạng tên-chủ/tên-repo)."
  [[ "$BRANCH" =~ ^[A-Za-z0-9._/-]{1,100}$ && "$BRANCH" != -* && "$BRANCH" != *..* && "$BRANCH" != *.lock &&
    "$BRANCH" != *. && "$BRANCH" != /* && "$BRANCH" != */ && "$BRANCH" != *//* && "$BRANCH" != .* &&
    "$BRANCH" != */.* ]] || die "Tên nhánh không hợp lệ: $BRANCH."
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
  [[ ! -L "$LOG" ]] && : >>"$LOG" 2>/dev/null && chmod 600 "$LOG" 2>/dev/null || LOG=/dev/null
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
  # mã nguồn + kiểm tra / cập nhật bản mới chỉ đi qua HTTPS (username + token classic), không cần SSH
  if tcp_ok github.com 443 && tcp_ok api.github.com 443; then
    pf_ok "Kết nối GitHub qua HTTPS (github.com, api.github.com cổng 443)"
  else
    pf_fail "Không kết nối được GitHub qua HTTPS (github.com / api.github.com cổng 443). Mở kết nối ra ngoài ở tường lửa VPS."
  fi
  if tcp_ok registry-1.docker.io 443; then pf_ok "Kết nối Docker Hub (tải image cơ sở)"; else
    pf_fail "Không kết nối được Docker Hub (registry-1.docker.io:443): không tải được image PostgreSQL/Caddy."
  fi
  if telegram_reachable; then pf_ok "Kết nối Telegram (api.telegram.org)"; else
    TG_BLOCKED=1
    pf_warn "Không gọi được api.telegram.org (nhà mạng có thể chặn Telegram) - bot sẽ nhận tin nhưng không trả lời được. Cần proxy: xem docs/huong-dan-telegram.md"
  fi

  # --- đồng hồ (mã xác thực 2 bước - nếu bật - và chứng chỉ SSL cần giờ đúng)
  local ntp
  ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
  if [[ "$ntp" == "yes" ]]; then
    pf_ok "Đồng hồ hệ thống đã đồng bộ (NTP)"
  else
    timedatectl set-ntp true >/dev/null 2>&1 || true
    pf_warn "Đồng hồ chưa đồng bộ NTP (đã bật tự đồng bộ). Giờ lệch làm SSL (và mã xác thực 2 bước, nếu bật) báo lỗi."
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

# Telegram Bot API ra ngoài: curl (nếu có) để thấy cả trường hợp nhà mạng cắt TLS; chưa có curl thì kiểm TCP
telegram_reachable() {
  if command -v curl >/dev/null 2>&1; then
    curl -sS -m 8 -o /dev/null https://api.telegram.org 2>/dev/null
  else
    tcp_ok api.telegram.org 443
  fi
}

# TELEGRAM_API_BASE_URL hợp lệ: cùng luật với isSafeTelegramBaseUrl (src/server/env.ts) - https, không user/mật khẩu,
# không ?query, không #
valid_tg_proxy() {
  [[ "$1" =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:([1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5]))?(/[A-Za-z0-9._~%/-]*)?$ ]]
}

# Hỏi proxy Telegram (Cloudflare Worker chuyển tiếp /bot<token>/…). -> TG_PROXY, TG_PROXY_SET=1 khi cần ghi .env
ask_telegram_proxy() {
  local cur url
  cur=$(env_get TELEGRAM_API_BASE_URL)
  TG_PROXY_SET=0
  say ""
  info "Telegram: máy chủ không gọi được api.telegram.org. Dùng proxy (vd Cloudflare Worker) để bot trả lời được — cách tạo: docs/huong-dan-telegram.md."
  [[ -z "$cur" ]] || info "Đang dùng: $cur (Enter để giữ, gõ - để bỏ proxy)."
  while :; do
    ask "Địa chỉ proxy Telegram (TELEGRAM_API_BASE_URL, vd https://tg-proxy.ten.workers.dev) — Enter để bỏ qua" "$cur"
    url=$(printf '%s' "$REPLY" | tr -d '[:space:]')
    url=${url%/}
    if [[ -z "$url" || "$url" == "-" ]]; then
      TG_PROXY=""
      [[ -z "$cur" ]] || TG_PROXY_SET=1
      warn "Không dùng proxy Telegram: bot nhận tin nhưng không trả lời được cho tới khi đặt TELEGRAM_API_BASE_URL (sudo ads-agent-deploy reconfigure)."
      return 0
    fi
    if ! valid_tg_proxy "$url"; then
      warn "Địa chỉ phải dạng https://tên-miền[/đường-dẫn], không kèm user/mật khẩu, ?query hay #."
      continue
    fi
    # Worker chuyển tiếp trả 404 cho "/" là đúng: chỉ cần có phản hồi HTTP
    if command -v curl >/dev/null 2>&1 && ! curl -sS -m 8 -o /dev/null "$url/" 2>/dev/null; then
      warn "Không kết nối được tới $url (sai địa chỉ Worker, hoặc Worker chưa chạy)."
      ask_yn "Vẫn dùng địa chỉ này?" N || continue
    fi
    TG_PROXY=$url
    TG_PROXY_SET=1
    ok "Proxy Telegram: $url"
    return 0
  done
}

apply_telegram_env() {
  [[ $TG_PROXY_SET -eq 1 ]] || return 0
  env_set TELEGRAM_API_BASE_URL "$TG_PROXY"
  chmod 600 "$DIR/.env"
  if [[ -n "$TG_PROXY" ]]; then ok "Đã ghi TELEGRAM_API_BASE_URL vào .env"; else ok "Đã bỏ TELEGRAM_API_BASE_URL trong .env"; fi
}

# ------------------------------------------------------------------------------------------------------------------
# Cài gói + Docker
# ------------------------------------------------------------------------------------------------------------------
# DPkg::Lock::Timeout: chờ (tối đa 10 phút) nếu apt đang bận, vd unattended-upgrades vừa chạy trên VPS mới
apt_install() { DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y -q --no-install-recommends "$@"; }

install_base() {
  local need=() p
  for p in git curl ca-certificates openssl; do
    dpkg -s "$p" >/dev/null 2>&1 || need+=("$p")
  done
  if [[ ${#need[@]} -gt 0 ]]; then
    info "Cài gói cần thiết: ${need[*]}…"
    run_logged "apt-get update" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 update -q || die "apt-get update lỗi."
    run_logged "apt-get install base" apt_install "${need[@]}" || die "Không cài được: ${need[*]}."
  fi
  ok "Đã có git, curl, openssl"
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
  chmod 644 /etc/apt/sources.list.d/docker.sources
  run_logged "apt-get update (docker)" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 update -q || die "apt-get update lỗi."
  run_logged "apt-get install docker" apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ||
    die "Cài Docker thất bại."
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || die "Đã cài Docker nhưng lệnh docker compose không chạy."
  ok "Đã cài Docker $(docker --version | sed 's/.*version \([^,]*\).*/\1/'), Compose $(docker compose version --short)"
}

# ------------------------------------------------------------------------------------------------------------------
# Username + token classic GitHub + mã nguồn
# ------------------------------------------------------------------------------------------------------------------
# Token: chỉ đi qua biến môi trường của tiến trình git (GIT_ASKPASS) và header curl đọc từ file 600 - không bao giờ
# nằm trong URL, argv, .git/config, log hay màn hình. Lưu trong $DIR/.env (UPDATE_GITHUB_USER / UPDATE_GITHUB_TOKEN,
# quyền 600) để `update` và nút cập nhật trên web dùng lại (worker kiểm tra bản mới, updater tải mã + build).
GH_USER="" GH_TOKEN=""

askpass_helper() {
  local h="$TMPD/askpass.sh"
  if [[ ! -x "$h" ]]; then
    cat >"$h" <<'EOF'
#!/bin/sh
case "$1" in
  *"'https://github.com'"* | *"@github.com'"*) ;;
  *) exit 1 ;;
esac
case "$1" in
  Username*) printf '%s\n' "$ADS_AGENT_GIT_USER" ;;
  *) printf '%s\n' "$ADS_AGENT_GIT_TOKEN" ;;
esac
EOF
    chmod 700 "$h"
  fi
  printf '%s' "$h"
}
# Mọi lệnh git của script: không đọc cấu hình hệ thống / global, không hook / fsmonitor / credential helper / ssh,
# không theo redirect (token chỉ tới github.com), luôn kiểm TLS, bỏ proxy trong cấu hình git, không submodule.
# Chạy với umask 022 (main đặt umask 077): file mã nguồn phải đọc được khi build image (user không phải root).
GIT_SAFE_OPTS=(-c credential.helper= -c core.sshCommand= -c core.hooksPath=/dev/null -c core.fsmonitor=false
  -c http.followRedirects=false -c http.sslVerify=true -c http.proxy= -c submodule.recurse=false
  -c fetch.recurseSubmodules=false)
git_safe() (
  umask 022
  GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git "${GIT_SAFE_OPTS[@]}" "$@"
)
# git_safe + username / token qua GIT_ASKPASS (chỉ lệnh nói chuyện với GitHub)
git_https() (
  umask 022
  ADS_AGENT_GIT_USER="$GH_USER" ADS_AGENT_GIT_TOKEN="$GH_TOKEN" GIT_ASKPASS="$(askpass_helper)" \
    GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git "${GIT_SAFE_OPTS[@]}" "$@"
)

# .git/config của chính thư mục cài đặt không được có mục chạy mã / đổi URL / lộ credential (cùng luật với updater:
# scripts/updater-core.ts UNSAFE_LOCAL_GIT_CONFIG_RE; git trả tên khoá chữ thường)
UNSAFE_GIT_CONFIG_RE='^(url\.|http\.|include|core\.(fsmonitor|hookspath|sshcommand|askpass)|credential|filter\.)'
check_local_git_config() {
  local keys
  keys=$(git_safe -C "$DIR" config --local --get-regexp "$UNSAFE_GIT_CONFIG_RE" 2>/dev/null | awk '{print $1}' | tr '\n' ' ' || true)
  [[ -z "${keys// /}" ]] ||
    die "Cấu hình git của $DIR có mục không an toàn: ${keys% }. Kiểm tra rồi xoá: cd $DIR && git config --local --unset <tên>"
}

# File riêng của máy chủ mà git không được ghi / xoá (cùng luật với scripts/updater-core.ts sensitiveTrackedPaths):
# .env* (trừ .env.example), *.key, *.pem, *.dump, backups/, deploy/caddy/certs/. Đọc danh sách NUL từ stdin.
sensitive_paths() {
  local p base lower
  while IFS= read -r -d '' p; do
    base=${p##*/}
    lower=${base,,}
    [[ "$base" == .env.example ]] && continue
    if [[ "$base" == .env || "$base" == .env.* || "$lower" == *.key || "$lower" == *.pem || "$lower" == *.dump ||
      "$p" == backups || "$p" == backups/* || "$p" == deploy/caddy/certs || "$p" == deploy/caddy/certs/* ]]; then
      printf '%s\n' "$p"
    fi
  done
}
repo_url() { printf 'https://github.com/%s.git' "$REPO"; }
repo_reachable() { git_https ls-remote --heads "$(repo_url)" "$BRANCH" >/dev/null 2>&1; }

# gh_api PATH -> mã HTTP; nội dung trả về ở $TMPD/gh.out, header ở $TMPD/gh.head. Token đọc từ file header 600.
gh_api() {
  local hdr="$TMPD/gh.hdr" code
  (
    umask 077
    printf 'Authorization: token %s\nAccept: application/vnd.github+json\nUser-Agent: ads-agent-deploy\nX-GitHub-Api-Version: 2022-11-28\n' "$GH_TOKEN" >"$hdr"
  )
  code=$(curl -sS -o "$TMPD/gh.out" -D "$TMPD/gh.head" -w '%{http_code}' --max-time 15 -H @"$hdr" "https://api.github.com$1" 2>/dev/null || true)
  rm -f "$hdr"
  printf '%s' "$code"
}

# token_check: 0 = token đọc được repo. Ghi lý do vào TOKEN_PROBLEM; TOKEN_CAN_WRITE=1 khi token có quyền GHI repo.
TOKEN_PROBLEM="" TOKEN_CAN_WRITE=0
token_check() {
  local code scopes perms login
  TOKEN_PROBLEM="" TOKEN_CAN_WRITE=0
  [[ -n "$GH_TOKEN" ]] || { TOKEN_PROBLEM="chưa có token"; return 1; }
  code=$(gh_api "/repos/$REPO")
  scopes=$(sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: *//p' "$TMPD/gh.head" 2>/dev/null | tr -d '\r' || true)
  case "$code" in
    200)
      if [[ -n "$scopes" && ! " ${scopes//,/ } " =~ [[:space:]]repo[[:space:]] ]]; then
        TOKEN_PROBLEM="token thiếu quyền repo (đang có: $scopes)"
        return 1
      fi
      perms=$(tr -d ' \r\n\t' <"$TMPD/gh.out" 2>/dev/null | grep -o '"permissions":{[^}]*}' | head -n 1 || true)
      if [[ "$perms" == *'"push":true'* || "$perms" == *'"admin":true'* ]]; then TOKEN_CAN_WRITE=1; fi
      # username thật của token (GitHub bỏ qua username khi xác thực bằng token, nhưng .env nên ghi đúng)
      if [[ "$(gh_api /user)" == "200" ]]; then
        login=$(tr -d ' \r\n\t' <"$TMPD/gh.out" | sed -n 's/.*"login":"\([A-Za-z0-9-]*\)".*/\1/p' | head -n 1 || true)
        if [[ -n "$login" && "${login,,}" != "${GH_USER,,}" ]]; then
          info "Token thuộc tài khoản $login (bạn nhập ${GH_USER:-<trống>}): dùng $login."
          GH_USER=$login
        fi
      fi
      rm -f "$TMPD/gh.out" "$TMPD/gh.head"
      return 0
      ;;
    401) TOKEN_PROBLEM="token sai, đã bị thu hồi hoặc hết hạn (GitHub trả 401)" ;;
    403) TOKEN_PROBLEM="token bị từ chối (403): thiếu quyền repo, hoặc tổ chức chặn token classic (SSO chưa authorize)" ;;
    404) TOKEN_PROBLEM="tài khoản ${GH_USER:-của token} không thấy repo $REPO (404): chưa được mời vào repo hoặc token thiếu quyền repo" ;;
    *) TOKEN_PROBLEM="không gọi được GitHub API (mã ${code:-?}), kiểm tra mạng" ;;
  esac
  rm -f "$TMPD/gh.out" "$TMPD/gh.head"
  return 1
}

token_write_warning() {
  [[ $TOKEN_CAN_WRITE -eq 1 ]] || return 0
  warn "Token của $GH_USER có quyền GHI vào repo $REPO (push/admin). Token nằm trên VPS nên khuyến nghị:"
  info "dùng một tài khoản GitHub riêng chỉ được mời quyền Read vào repo, tạo token classic (quyền repo) từ tài khoản đó,"
  info "rồi đổi bằng: sudo ads-agent-deploy token. (Chỉ là khuyến nghị, cài đặt vẫn tiếp tục.)"
}

# Ghi username/token + nguồn cập nhật vào .env (quyền 600): worker kiểm tra bản mới, updater tải mã + build.
save_token_env() {
  [[ -f "$DIR/.env" ]] || return 0
  env_set UPDATE_GITHUB_USER "$GH_USER"
  env_set UPDATE_GITHUB_TOKEN "$GH_TOKEN"
  env_set UPDATE_REPO "$REPO"
  env_set UPDATE_SOURCE branch
  env_set UPDATE_BRANCH "$BRANCH"
  chmod 600 "$DIR/.env"
}

# Hỏi username + token đến khi dùng được (đọc được repo bằng API và bằng git). Không lưu: người gọi lưu.
ask_token() {
  say ""
  say "   ${C_BLD}Username + token classic GitHub (để tải mã nguồn và cập nhật bản mới từ trang chủ):${C_RST}"
  say "     GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic) → Generate new token"
  say "     Tick quyền ${C_BLD}repo${C_RST} → Generate → copy token (bắt đầu bằng ghp_). Tài khoản phải được mời vào repo $REPO."
  info "Khuyến nghị: tài khoản GitHub riêng cho máy chủ, chỉ được mời quyền Read vào repo."
  while :; do
    ask "Username GitHub" "$GH_USER"
    GH_USER=$(printf '%s' "$REPLY" | tr -d '[:space:]')
    [[ "$GH_USER" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$ ]] || { warn "Username không hợp lệ."; continue; }
    ask_secret "Token classic (ẩn khi gõ)"
    GH_TOKEN=$(printf '%s' "$REPLY" | tr -d '[:space:]')
    REPLY=""
    [[ -n "$GH_TOKEN" ]] || { warn "Chưa nhập token."; continue; }
    [[ "$GH_TOKEN" =~ ^[A-Za-z0-9_]+$ ]] || { warn "Token chỉ gồm chữ, số và dấu gạch dưới (ghp_…). Dán lại."; continue; }
    if token_check && repo_reachable; then
      ok "Token hoạt động: tài khoản $GH_USER đọc được repo $REPO (nhánh $BRANCH)"
      token_write_warning
      return 0
    fi
    warn "Không dùng được token: ${TOKEN_PROBLEM:-git không đọc được repo hoặc nhánh $BRANCH}. Nhập lại."
  done
}

# Token đã lưu: .env (bản cài mới) hoặc /etc/ads-agent/git-auth (bản cài cũ) -> GH_USER / GH_TOKEN
load_token() {
  GH_USER=$(env_get UPDATE_GITHUB_USER)
  GH_TOKEN=$(env_get UPDATE_GITHUB_TOKEN)
  if [[ -z "$GH_TOKEN" && -f "$LEGACY_GIT_CRED" ]]; then
    GH_USER=$(env_get GIT_USER "$LEGACY_GIT_CRED")
    GH_TOKEN=$(env_get GIT_TOKEN "$LEGACY_GIT_CRED")
    [[ -z "$GH_TOKEN" ]] || info "Bản cài cũ: chuyển token GitHub từ $LEGACY_GIT_CRED sang $DIR/.env"
  fi
}

# Bản cài cũ: gỡ file token riêng, Deploy key + known_hosts riêng của Ads Agent, core.sshCommand trong repo.
cleanup_legacy_auth() {
  local removed=0
  if [[ -f "$LEGACY_GIT_CRED" ]]; then
    rm -f "$LEGACY_GIT_CRED"
    rmdir "$LEGACY_GIT_CRED_DIR" 2>/dev/null || true
    removed=1
  fi
  if [[ -f "$LEGACY_KEY" || -f "$LEGACY_KEY.pub" ]]; then
    rm -f "$LEGACY_KEY" "$LEGACY_KEY.pub" "$LEGACY_KNOWN_HOSTS"
    ok "Đã gỡ Deploy key cũ khỏi máy. Xoá luôn Deploy key trên GitHub: https://github.com/$REPO/settings/keys"
    removed=1
  fi
  [[ -d "$DIR/.git" ]] && git_safe -C "$DIR" config --unset core.sshCommand >/dev/null 2>&1 || true
  [[ $removed -eq 0 ]] || log "   đã gỡ cách xác thực cũ (Deploy key / git-auth)"
  return 0
}

# Cài mới: luôn hỏi. update / reconfigure: dùng token đã lưu nếu còn hoạt động, hết hạn thì hỏi token mới.
ensure_token() {
  local mode=${1:-reuse}
  if [[ "$mode" == "reuse" ]]; then
    load_token
    if [[ -n "$GH_TOKEN" ]]; then
      if token_check; then
        ok "Dùng token GitHub đã lưu của ${GH_USER:-tài khoản này}"
        token_write_warning
        return 0
      fi
      warn "Token GitHub đã lưu không dùng được: ${TOKEN_PROBLEM}."
    elif [[ -f "$LEGACY_KEY" || "$(env_get ADS_AGENT_GIT_AUTH "$CONF")" == "key" ]]; then
      warn "Bản cài này dùng Deploy key, cách này đã bỏ. Từ giờ Ads Agent dùng username + token classic GitHub (lưu trong .env)."
    fi
  fi
  ask_token
}

set_repo_remote() {
  git_safe -C "$DIR" config --unset core.sshCommand >/dev/null 2>&1 || true
  git_safe -C "$DIR" remote set-url origin "$(repo_url)"
}

fetch_source() {
  if [[ -d "$DIR/.git" ]]; then
    set_repo_remote
    check_local_git_config
    run_logged "git fetch" git_https -C "$DIR" fetch --prune origin "$BRANCH" ||
      die "git fetch thất bại (token hết hạn hoặc bị thu hồi?). Đổi token: sudo ads-agent-deploy token"
    local bad
    bad=$(git_safe -C "$DIR" diff --name-only -z HEAD "origin/$BRANCH" 2>/dev/null | sensitive_paths | head -n 5 | tr '\n' ' ' || true)
    [[ -z "${bad// /}" ]] ||
      die "Mã mới trên GitHub đụng tới file bí mật / dữ liệu riêng của máy chủ (${bad% }) nên không cập nhật: báo noti.vn."
    # .env không bao giờ bị git ghi đè (--no-overwrite-ignore), vẫn giữ một bản sao trước khi đổi mã
    [[ -f "$DIR/.env" ]] && cp -p "$DIR/.env" "$DIR/.env.bak"
    if ! run_logged "git merge --ff-only" git_safe -C "$DIR" merge --ff-only --no-overwrite-ignore "origin/$BRANCH"; then
      die "Thư mục $DIR có thay đổi cục bộ (hoặc file bị git bỏ qua trùng tên file mới) nên không cập nhật được. Xem: cd $DIR && git status"
    fi
    ok "Mã nguồn đã cập nhật: $(git_safe -C "$DIR" log -1 --format='%h %s' | cut -c1-80)"
  elif [[ -e "$DIR" && -n "$(ls -A "$DIR" 2>/dev/null)" ]]; then
    die "Thư mục $DIR đã có dữ liệu nhưng không phải bản cài từ git. Đổi thư mục: sudo ADS_AGENT_DIR=/opt/ads-agent-2 bash $0"
  else
    install -d -m 755 "$(dirname "$DIR")"
    run_logged "git clone" git_https clone --branch "$BRANCH" --single-branch "$(repo_url)" "$DIR" ||
      die "git clone thất bại."
    local bad
    bad=$(git_safe -C "$DIR" ls-files -z 2>/dev/null | sensitive_paths | head -n 5 | tr '\n' ' ' || true)
    if [[ -n "${bad// /}" ]]; then
      # vừa clone trong lần chạy này: xoá để không dùng chung .env / khoá của repo cho máy này
      rm -rf -- "$DIR"
      die "Repo đang chứa file bí mật / dữ liệu riêng của máy chủ (${bad% }) nên không cài (mọi máy sẽ dùng chung khoá): báo noti.vn."
    fi
    set_repo_remote
    ok "Đã tải mã nguồn vào $DIR ($(git_safe -C "$DIR" log -1 --format='%h'))"
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

# ------------------------------------------------------------------------------------------------------------------
# Cổng (2026-11-09): ai đang giữ cổng nào, kiểm lại ngay trước `docker compose up`
# ------------------------------------------------------------------------------------------------------------------
# port_busy PORT: có chương trình trên máy đang nghe TCP PORT (mọi địa chỉ, kể cả docker-proxy của cổng publish)
port_busy() { [[ -n "$(ss -Hltn "( sport = :$1 )" 2>/dev/null || true)" ]]; }

# port_users PORT...: tên các chương trình đang nghe các cổng đó ("" khi trống / không rõ)
port_users() {
  local port out all=""
  for port in "$@"; do
    out=$(ss -Hltnp "( sport = :$port )" 2>/dev/null || true)
    [[ -n "$out" ]] && all+=" $(grep -o 'users:(("[^"]*"' <<<"$out" | sed 's/users:(("//; s/"$//' | tr '\n' ' ' || true)"
  done
  # tên do chương trình khác đặt (comm): chỉ giữ ký tự in được trước khi ra màn hình root / log
  tr ' ' '\n' <<<"$all" | sed '/^$/d' | sort -u | tr '\n' ' ' | LC_ALL=C tr -cd 'A-Za-z0-9._ -' | sed 's/ $//' || true
}

# held_by_us SERVICE CONTAINER_PORT HOST_PORT: container SERVICE của Ads Agent đang publish CONTAINER_PORT ra HOST_PORT
held_by_us() {
  [[ -f "$DIR/.env" ]] || return 1
  local bound
  bound=$(dc_build port "$1" "$2" 2>/dev/null | head -n 1 || true)
  [[ -n "$bound" && "$bound" == *":$3" ]]
}

# ensure_ports_before_up: ngay trước `docker compose up`. Cách 2/3 (Caddy mở 80/443 ra Internet) mà cổng vừa bị chương
# trình khác giữ → báo rõ ai đang giữ + cách xử lý, thay vì lỗi "address already in use" khó hiểu của Docker. 80/443
# không bao giờ đổi sang số khác: Let's Encrypt, trình duyệt và proxy Cloudflare cần đúng 80/443. Cách 1 (Tunnel) không
# mở cổng nào (Caddy chỉ nghe 127.0.0.1, cổng do Docker tự chọn) nên không bao giờ trùng.
# bind_port BIND DEFAULT: cổng trên máy của một binding compose "[IP:]cổng" (CADDY_HTTP_PORT_BIND…); "" = không mở ra
# Internet (127.0.0.1:… = Cloudflare Tunnel, Docker tự chọn cổng nội bộ) hoặc không phải số
bind_port() {
  local bind=${1:-$2}
  [[ "$bind" == 127.0.0.1:* ]] && return 0
  bind=${bind##*:}
  [[ "$bind" =~ ^[0-9]+$ ]] && printf '%s' "$bind"
  return 0
}

ensure_ports_before_up() {
  local users http https
  [[ "$(env_get CADDY_REPLICAS)" == "0" ]] && return 0
  http=$(bind_port "$(env_get CADDY_HTTP_PORT_BIND)" 80)
  https=$(bind_port "$(env_get CADDY_HTTPS_PORT_BIND)" 443)
  if { [[ -n "$http" ]] && port_busy "$http" && ! held_by_us caddy 80 "$http"; } ||
    { [[ -n "$https" ]] && port_busy "$https" && ! held_by_us caddy 443 "$https"; }; then
    users=$(port_users $http $https)
    die "Cổng $http/$https đang bị ${users:-chương trình khác} dùng nên Caddy của Ads Agent không mở được. Không đổi sang cổng khác được (Let's Encrypt, trình duyệt và Cloudflare cần đúng 80/443). Cách xử lý: tắt chương trình đó (nếu không phải Ads MCP), hoặc chọn cách 1 Cloudflare Tunnel (không cần cổng nào): sudo ads-agent-deploy reconfigure"
  fi
  return 0
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
  local args=(--domain "$DOMAIN" --email "$EMAIL" --ssl "$ACCESS")
  (cd "$DIR" && export HOST_PROJECT_DIR="$DIR" && run_logged "gen-secrets" sh scripts/gen-secrets.sh "${args[@]}") ||
    die "Không tạo được .env."
  [[ -s "$DIR/.env" ]] || die "Không thấy $DIR/.env sau khi sinh."
  chmod 600 "$DIR/.env"
  ok "Đã tạo $DIR/.env (quyền 600, secret ngẫu nhiên)"
  warn "Sao lưu riêng file $DIR/.env (nhất là ENCRYPTION_KEYS): mất nó thì không giải mã được kết nối đã lưu."
}

# Bật cập nhật bằng nút trên web: username/token + nguồn mã (UPDATE_*) và service updater (COMPOSE_PROFILES=updater).
apply_update_env() {
  save_token_env
  env_set COMPOSE_PROFILES "$(profiles_with_updater)"
  env_set HOST_PROJECT_DIR "$DIR"
  chmod 600 "$DIR/.env"
  # thư mục docker login riêng mà updater mount chỉ đọc (bản build từ mã nguồn không cần đăng nhập GHCR)
  install -d -m 700 "$UPDATER_DOCKER_DIR"
  ok "Đã lưu username + token GitHub và nguồn cập nhật (nhánh $BRANCH của $REPO) vào $DIR/.env (quyền 600)"
}

# 0 = có yêu cầu cập nhật pending/running trong DB (system_update_requests). DB không chạy = không có.
web_update_in_progress() {
  local n
  n=$(cd "$DIR" && docker compose exec -T db psql -U adsagent -d adsagent -tAc \
    "SELECT count(*) FROM system_update_requests WHERE status IN ('pending', 'running')" 2>/dev/null | tr -dc '0-9' || true)
  [[ -n "$n" && "$n" != "0" ]]
}

updater_image_present() {
  local img ver
  img=$(env_get APP_IMAGE)
  ver=$(env_get APP_VERSION)
  docker image inspect "${img:-ghcr.io/notivn/ads-agent-simple}-updater:$ver" >/dev/null 2>&1
}

build_and_start() {
  local ver
  ver=$(pkg_version)
  [[ -n "$ver" ]] || die "Không đọc được phiên bản trong $DIR/package.json."
  info "Đang build image ứng dụng và updater từ mã nguồn (lần đầu 5-15 phút, tuỳ cấu hình VPS)…"
  local t0=$SECONDS profiles
  # updater + the AI services enabled with `sudo ads-agent ai enable` (their image is built from gateway/ only then)
  profiles=$(build_profiles)
  [[ "$profiles" == updater ]] || info "Dịch vụ AI đang bật: ${profiles#updater,} - build thêm image dịch vụ AI (thư mục gateway/)"
  # APP_VERSION only in the build's env: .env keeps the running version until the new images exist
  (export APP_VERSION="$ver" APP_BUILD_VERSION="$ver" COMPOSE_PROFILES="$profiles" && run_logged "docker compose build" dc_build build) ||
    die "Build image thất bại (thường do mạng tải gói chập chờn, thiếu RAM hoặc ổ đĩa). Bản đang chạy không bị ảnh hưởng. Chạy lại đúng lệnh vừa rồi để thử tiếp — phần đã build được giữ trong cache. Nhật ký: $LOG"
  env_set APP_VERSION "$ver"
  ok "Build xong v$ver trong $(((SECONDS - t0) / 60)) phút"
  info "Đang khởi động (database → migrate → web, worker, updater, Caddy)…"
  # --remove-orphans (COMPOSE_PROFILES from .env: updater + the enabled AI profiles, kept by profiles_with_updater):
  # also removes the gateway-chatgpt / gateway-gemini containers of installs <= 0.2.x (gateways removed in 0.3.0);
  # volumes are never removed (docs/van-hanh.md). The ai-* services are defined in docker-compose.yml: not orphans.
  ensure_ports_before_up
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
  env_set ADS_AGENT_GIT_AUTH token "$CONF"
  chmod 644 "$CONF"
  ok "Đã cài lệnh: sudo ads-agent-deploy (cập nhật / đổi cách truy cập / đổi token), sudo ads-agent (trạng thái, log, sao lưu…)"
}

# chỉ image lơ lửng của Ads Agent (nhãn vn.noti.ads-agent=1, docker-compose.build.yml): không bao giờ dọn image /
# build cache của Ads MCP hay dự án khác trên cùng máy (R19)
prune_images() {
  docker image prune -f --filter label=vn.noti.ads-agent=1 >/dev/null 2>&1 || true
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
  printf '     (dán vào ô "Mã thiết lập (SETUP_TOKEN)" rồi tạo quản trị viên)\n'
  printf '     Bật xác thực 2 bước trong Tài khoản nếu muốn (khuyến nghị).\n'
  printf '  3. Làm theo trình hướng dẫn: kết nối Ads MCP → lõi AI → Telegram → đội mặc định.\n\n'
  printf '  Cập nhật bản mới:   bấm "Cập nhật ngay" ở trang Tổng quan (hoặc: sudo ads-agent-deploy update)\n'
  printf '                      Bản mới = phiên bản trong package.json ở đầu nhánh %s của %s.\n' "$BRANCH" "$REPO"
  if [[ $TG_BLOCKED -eq 1 && -z "$(env_get TELEGRAM_API_BASE_URL)" ]]; then
    printf '  %sTelegram:%s           máy chủ không gọi được api.telegram.org - đặt proxy: sudo ads-agent-deploy reconfigure\n' "$C_YLW$C_BLD" "$C_RST"
    printf '                      (cách tạo Cloudflare Worker: docs/huong-dan-telegram.md)\n'
  fi
  printf '  Đổi token GitHub:   sudo ads-agent-deploy token\n'
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
  [[ $TG_BLOCKED -eq 0 ]] || ask_telegram_proxy
  step "Gói hệ thống, Docker, swap"
  install_base
  install_docker
  ensure_swap
  step "Quyền đọc mã nguồn trên GitHub"
  ensure_token ask
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
  apply_update_env
  apply_telegram_env
  cleanup_legacy_auth
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
  STEP_TOTAL=5
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Cần quyền root. Chạy lại: sudo ads-agent-deploy update"
  [[ -f "$DIR/.env" && -d "$DIR/.git" ]] || die "Chưa có bản cài ở $DIR. Chạy: sudo bash deploy-vps.sh"
  { : >>"$LOG" && chmod 600 "$LOG"; } 2>/dev/null || LOG=/dev/null
  DOMAIN=$(env_get APP_DOMAIN)
  ACCESS=$(current_access)
  # một lần cập nhật bấm từ trang web (updater) đang chờ / đang chạy: không chạy song song (cùng sửa mã nguồn + image)
  if web_update_in_progress; then
    die "Đang có một lần cập nhật bấm từ trang web (Tổng quan → Cập nhật ngay) chờ hoặc đang chạy. Đợi nó xong (xem: sudo ads-agent logs updater) rồi chạy lại."
  fi
  if (cd "$DIR" && docker compose ps --status running --services 2>/dev/null | grep -qx updater); then
    (cd "$DIR" && docker compose stop updater) >>"$LOG" 2>&1 && UPDATER_STOPPED=1 && info "Tạm dừng dịch vụ cập nhật của web trong lúc chạy lệnh này."
  fi
  step "Quyền đọc mã nguồn trên GitHub"
  # token trong .env (bản cài cũ: /etc/ads-agent/git-auth hoặc Deploy key -> chuyển sang .env); hết hạn thì hỏi mới
  ensure_token reuse
  save_token_env
  cleanup_legacy_auth
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
  local before after need_build=0
  before=$(git_safe -C "$DIR" rev-parse --short HEAD)
  fetch_source
  after=$(git_safe -C "$DIR" rev-parse --short HEAD)
  # bản cài cũ chưa có image updater (cập nhật bằng nút trên web bị tắt): build để bật
  updater_image_present || need_build=1
  if [[ "$before" == "$after" && $need_build -eq 0 ]] && ! ask_yn "Không có mã mới ($after). Vẫn build lại và khởi động lại?" N; then
    apply_update_env
    run_logged "docker compose up worker updater" dc_build up -d --no-build worker updater ||
      warn "Không khởi động lại được worker / updater: sudo ads-agent status"
    ok "Không có mã mới. Cấu hình cập nhật trong .env đã được làm mới."
    exit 0
  fi
  step "Build và khởi động lại"
  apply_update_env
  build_and_start
  step "Kiểm tra sức khoẻ"
  wait_healthy
  install_commands
  prune_images
  say ""
  ok "Đã cập nhật lên v$(pkg_version) ($after). Địa chỉ: https://$DOMAIN"
  info "Lần sau: bấm \"Cập nhật ngay\" ở trang Tổng quan khi có bản mới (hoặc chạy lại lệnh này)."
}

cmd_reconfigure() {
  STEP_TOTAL=5
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Cần quyền root. Chạy lại: sudo ads-agent-deploy reconfigure"
  [[ -f "$DIR/.env" ]] || die "Chưa có bản cài ở $DIR. Chạy: sudo bash deploy-vps.sh"
  { : >>"$LOG" && chmod 600 "$LOG"; } 2>/dev/null || LOG=/dev/null
  step "Quyền đọc mã nguồn trên GitHub"
  ensure_token reuse
  save_token_env
  cleanup_legacy_auth
  [[ -d "$DIR/.git" ]] && set_repo_remote
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
  if ! telegram_reachable; then
    warn "Không gọi được api.telegram.org (nhà mạng có thể chặn Telegram) - bot sẽ nhận tin nhưng không trả lời được. Cần proxy: xem docs/huong-dan-telegram.md"
    ask_telegram_proxy
  elif [[ -n "$(env_get TELEGRAM_API_BASE_URL)" ]]; then
    ask_yn "Đang dùng proxy Telegram $(env_get TELEGRAM_API_BASE_URL). Đổi hoặc bỏ?" N && ask_telegram_proxy
  fi
  apply_access_env
  apply_telegram_env
  if updater_image_present; then
    apply_update_env
  else
    warn "Chưa có image updater (bản cài cũ): chạy sudo ads-agent-deploy update để bật nút cập nhật trên web."
  fi
  step "Áp dụng"
  ensure_ports_before_up
  run_logged "docker compose up (reconfigure)" dc_build up -d --no-build --remove-orphans || die "docker compose up thất bại."
  (cd "$DIR" && docker compose restart caddy) >>"$LOG" 2>&1 || true
  step "Kiểm tra"
  wait_healthy
  check_public
  ok "Đã chuyển sang: $(access_label)"
}

cmd_token() {
  STEP_TOTAL=2
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Cần quyền root. Chạy lại: sudo ads-agent-deploy token"
  [[ -f "$DIR/.env" ]] || die "Chưa có bản cài ở $DIR. Chạy: sudo bash deploy-vps.sh"
  { : >>"$LOG" && chmod 600 "$LOG"; } 2>/dev/null || LOG=/dev/null
  step "Username + token GitHub mới"
  load_token
  ensure_token ask
  save_token_env
  cleanup_legacy_auth
  [[ -d "$DIR/.git" ]] && set_repo_remote
  ok "Đã lưu username + token mới vào $DIR/.env (quyền 600)"
  step "Áp dụng cho worker (kiểm tra bản mới) và updater (tải mã + build)"
  local svcs=(worker)
  if updater_image_present; then
    env_set COMPOSE_PROFILES "$(profiles_with_updater)"
    svcs+=(updater)
  fi
  run_logged "docker compose up ${svcs[*]}" dc_build up -d --no-build "${svcs[@]}" ||
    die "docker compose up thất bại: sudo ads-agent status"
  ok "Đã áp dụng. Kiểm tra trong web: Cài đặt → Cập nhật hệ thống → Kiểm tra ngay."
  info "Nhớ xoá token cũ ở https://github.com/settings/tokens"
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
Ads Agent by: noti.vn - triển khai nhanh lên VPS (username + token classic GitHub, build trên VPS)
  curl -fsSL https://raw.githubusercontent.com/notivn/ads-agent-simple-install/main/deploy.sh | sudo bash
  sudo bash deploy-vps.sh              cài mới; máy đã cài thì hỏi: cập nhật / đổi cách truy cập / đổi token
  sudo ads-agent-deploy update         kéo mã mới nhất + build lại + khởi động lại (dữ liệu giữ nguyên)
  sudo ads-agent-deploy reconfigure    đổi cách đưa web ra Internet (Tunnel / trỏ IP / proxy Cloudflare)
  sudo ads-agent-deploy token          đổi username / token classic GitHub (lưu trong .env)
  sudo ads-agent-deploy setup-key      in lại mã thiết lập để tạo quản trị viên đầu tiên
Sau khi cài, bản mới (version trong package.json ở đầu nhánh) cập nhật bằng nút "Cập nhật ngay" ở trang Tổng quan.
Biến tuỳ chọn: ADS_AGENT_REPO (mặc định notivn/Ads-Agent-Simple), ADS_AGENT_BRANCH (main), ADS_AGENT_DIR (/opt/ads-agent)
EOF
}

main() {
  local cmd=${1:-}
  # mọi file script tạo ra chỉ root đọc được (file cần quyền khác đặt mode rõ ràng; git chạy với umask 022)
  umask 077
  # nhật ký không bao giờ ghi qua symlink (có thể trỏ tới file khác của hệ thống)
  [[ ! -L "$LOG" ]] || LOG=/dev/null
  TMPD=$(mktemp -d /root/.ads-agent-deploy.XXXXXX 2>/dev/null || mktemp -d)
  case "$cmd" in
    help | -h | --help)
      cmd_help
      return 0
      ;;
  esac
  resolve_source
  case "$cmd" in
    "" | install)
      if [[ -f "$DIR/.env" && -d "$DIR/.git" ]]; then
        printf '%sAds Agent đã được cài ở %s (tên miền %s).%s\n' "$C_BLD" "$DIR" "$(env_get APP_DOMAIN)" "$C_RST"
        printf '   1) Cập nhật lên mã mới nhất\n   2) Đổi cách truy cập Internet\n   3) Đổi username / token GitHub\n   4) Thoát\n'
        tty_ok || die "Cần chạy trong terminal."
        ask "Chọn" "1"
        case "$REPLY" in
          1) cmd_update ;;
          2) cmd_reconfigure ;;
          3) cmd_token ;;
          *) exit 0 ;;
        esac
      else
        printf '%sAds Agent by: noti.vn — triển khai nhanh lên VPS%s\n' "$C_BLD" "$C_RST"
        cmd_install
      fi
      ;;
    update) cmd_update ;;
    reconfigure) cmd_reconfigure ;;
    token) cmd_token ;;
    setup-key) cmd_setup_key ;;
    *) die "Lệnh không hợp lệ: $cmd. Xem: sudo bash $0 help" ;;
  esac
}

# `source deploy-vps.sh` (tests: scripts/ports.test.ts) only loads the functions: `return` works only when sourced. Never
# a BASH_SOURCE / env-var check: under `curl … | sudo bash` BASH_SOURCE[0] is empty, and a leftover exported variable
# would make the one-line install silently do nothing.
if ! (return 0 2>/dev/null); then
  main "$@"
fi
