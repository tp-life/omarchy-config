#!/usr/bin/env bash
# =============================================================================
# omarchy-init.sh —— Omarchy 重装后一键恢复个人环境
#
#   1. Neovim 配置： https://github.com/tp-life/nvim.git
#   2. 默认 shell： fish（并补上 Omarchy 原本在 bash 里提供的 PATH/工具初始化）
#   3. 代理工具：   https://github.com/tp-life/proxyd.git
#                   默认节点 http://10.0.2.2:7890，以 root 运行并开启 TUN(gvisor)，
#                   systemd 系统服务 proxyd.service 开机自启
#   4. SSH：        安装 openssh，启用 sshd 并开机自启
#   5. 输入法：     fcitx5 小鹤双拼（默认）+ 全拼，Ctrl+Shift 切换
#
# 用法：
#   bash omarchy-init.sh                 # 全部执行
#   bash omarchy-init.sh nvim fish       # 只执行指定步骤（nvim / fish / proxyd / ssh / ime）
#
# 可用环境变量：
#   PROXY_HOST=10.0.2.2  PROXY_PORT=7890  PROXY_SCHEME=http
#   BOOTSTRAP_PROXY=1    安装过程中（git/curl/pacman）先走 PROXY_HOST:PROXY_PORT
#                        适合 GitHub 直连不通的情况
#   SRC_DIR=~/.local/src 仓库克隆目录
#   PROXYD_REINSTALL=1   重新安装 proxyd
#   PROXYD_FROM_RELEASE=1 proxyd 优先用 GitHub Release（默认源码编译）
#   SHUANGPIN_PROFILE=Xiaohe  双拼方案（Xiaohe / Ziranma / MS / Sogou / ABC / Zhongwenzhixing / PinyinJiajia）
#
# 脚本可以重复执行：已存在的内容会更新或跳过，不会重复写入。
# =============================================================================
set -Eeuo pipefail

# ---------------------------- 配置 -------------------------------------------
NVIM_REPO="${NVIM_REPO:-https://github.com/tp-life/nvim.git}"
PROXYD_REPO="${PROXYD_REPO:-https://github.com/tp-life/proxyd.git}"
PROXYD_GH="tp-life/proxyd"
PROXYD_BIN="${PROXYD_BIN:-/usr/local/bin/proxyd}"
PROXYD_CONF="${PROXYD_CONF:-/root/.config/proxyd/config.yaml}"
PROXYD_UNIT="/etc/systemd/system/proxyd.service"

SHUANGPIN_PROFILE="${SHUANGPIN_PROFILE:-Xiaohe}"

PROXY_HOST="${PROXY_HOST:-10.0.2.2}"
PROXY_PORT="${PROXY_PORT:-7890}"
PROXY_SCHEME="${PROXY_SCHEME:-http}"     # 7890 一般是 Clash 混合端口，http/socks5 都可
PROXY_NODE_NAME="${PROXY_NODE_NAME:-host-${PROXY_HOST}-${PROXY_PORT}}"

SRC_DIR="${SRC_DIR:-$HOME/.local/src}"
BIN_DIR="$HOME/.local/bin"
TS="$(date +%Y%m%d-%H%M%S)"

# ---------------------------- 工具函数 ---------------------------------------
c_info=$'\e[1;34m'; c_ok=$'\e[1;32m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'
info() { printf '%s==>%s %s\n' "$c_info" "$c_off" "$*"; }
ok()   { printf '%s ✔%s  %s\n' "$c_ok" "$c_off" "$*"; }
warn() { printf '%s !%s  %s\n' "$c_warn" "$c_off" "$*" >&2; }
die()  { printf '%s ✘%s  %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }
trap 'die "第 $LINENO 行出错：$BASH_COMMAND"' ERR

have() { command -v "$1" >/dev/null 2>&1; }

# 安装缺失的 pacman 包（Omarchy 基于 Arch）
pkg() {
  local missing=()
  for p in "$@"; do pacman -Qi "$p" >/dev/null 2>&1 || missing+=("$p"); done
  ((${#missing[@]})) || return 0
  info "安装软件包：${missing[*]}"
  sudo --preserve-env=http_proxy,https_proxy,all_proxy \
    pacman -S --needed --noconfirm "${missing[@]}"
}

# 克隆或更新仓库
git_sync() {
  local repo="$1" dir="$2"
  if [[ -d "$dir/.git" ]]; then
    info "更新 $dir"
    git -C "$dir" pull --ff-only || warn "$dir 有本地改动，跳过 pull"
  else
    info "克隆 $repo -> $dir"
    mkdir -p "$(dirname "$dir")"
    git clone --depth=1 "$repo" "$dir"
  fi
}

# 把已存在的文件/目录（不是指向目标的链接）备份掉
backup() {
  local p="$1"
  if [[ -e "$p" || -L "$p" ]]; then
    mv "$p" "$p.bak-$TS"
    warn "已备份 $p -> $p.bak-$TS"
  fi
}

preflight() {
  [[ $EUID -ne 0 ]] || die "请用普通用户运行（需要时脚本会自己调用 sudo）"
  have pacman || die "未找到 pacman，此脚本面向 Omarchy / Arch"
  sudo -v || die "需要 sudo 权限"
  # 保持 sudo 不过期
  while true; do sudo -n true; sleep 50; kill -0 "$$" || exit; done 2>/dev/null &

  if [[ "${BOOTSTRAP_PROXY:-0}" == 1 ]]; then
    export http_proxy="http://${PROXY_HOST}:${PROXY_PORT}" https_proxy="http://${PROXY_HOST}:${PROXY_PORT}"
    export all_proxy="$http_proxy" HTTP_PROXY="$http_proxy" HTTPS_PROXY="$http_proxy"
    info "安装过程使用代理 $http_proxy"
  fi

  pkg git curl base-devel
  mkdir -p "$SRC_DIR" "$BIN_DIR"
}

# ============================ 1. Neovim ======================================
setup_nvim() {
  info "[1/5] 配置 Neovim"
  pkg neovim nodejs npm ripgrep fd unzip

  local dir="$SRC_DIR/nvim"
  git_sync "$NVIM_REPO" "$dir"

  # Omarchy 自带一份 LazyVim 配置在 ~/.config/nvim，这里替换成你的仓库（软链接）
  local target="$HOME/.config/nvim"
  if [[ "$(readlink -f "$target" 2>/dev/null)" == "$(readlink -f "$dir")" ]]; then
    ok "~/.config/nvim 已指向 $dir"
  elif [[ -x "$dir/install.sh" ]]; then
    # 仓库自带安装脚本：检查依赖、备份旧配置、链接配置、预装插件和 LSP
    (cd "$dir" && ./install.sh)
  else
    backup "$target"
    # 旧的插件/缓存可能和新配置冲突，一并备份
    for d in "$HOME/.local/share/nvim" "$HOME/.local/state/nvim" "$HOME/.cache/nvim"; do backup "$d"; done
    ln -s "$dir" "$target"
    info "预装插件（lazy.nvim）……"
    nvim --headless "+Lazy! sync" +qa || warn "插件安装未完全成功，首次打开 nvim 时会继续"
  fi
  ok "Neovim 配置完成"
}

# ============================ 2. fish ========================================
setup_fish() {
  info "[2/5] 设置 fish 为默认 shell"
  pkg fish

  local fish_bin; fish_bin="$(command -v fish)"
  grep -qxF "$fish_bin" /etc/shells || echo "$fish_bin" | sudo tee -a /etc/shells >/dev/null

  if [[ "$(getent passwd "$USER" | cut -d: -f7)" != "$fish_bin" ]]; then
    sudo chsh -s "$fish_bin" "$USER"
    ok "默认 shell 已改为 $fish_bin（重新登录后生效）"
  else
    ok "默认 shell 已经是 fish"
  fi

  # Omarchy 的 PATH、mise、starship、zoxide 等初始化写在 bash 的 rc 里，
  # 切到 fish 后需要在 conf.d 里补上，否则 omarchy-* 命令等会找不到。
  local conf="$HOME/.config/fish/conf.d/00-omarchy.fish"
  mkdir -p "$(dirname "$conf")"
  cat >"$conf" <<'EOF'
# 由 omarchy-init.sh 生成：补齐 Omarchy 在 bash 中提供的环境
set -g fish_greeting

fish_add_path -g ~/.local/bin
test -d ~/.local/share/omarchy/bin; and fish_add_path -g ~/.local/share/omarchy/bin

set -gx EDITOR nvim
set -gx VISUAL nvim

if status is-interactive
    type -q mise;     and mise activate fish | source
    type -q starship; and starship init fish | source
    type -q zoxide;   and zoxide init fish | source
    type -q fzf;      and fzf --fish 2>/dev/null | source
end
EOF
  ok "已写入 $conf"
}

# ============================ 3. proxyd ======================================
# 与当前在用的运行方式保持一致：
#   - 以 root 运行（TUN 需要 root / CAP_NET_ADMIN），命令为 `proxyd serve -c $PROXYD_CONF`
#   - 配置在 /root/.config/proxyd/config.yaml，TUN 使用 gvisor 栈
#   - 由 systemd 系统级服务开机自启（`proxyd autostart on` 只注册 user unit，拿不到 TUN 权限）
# 二进制默认从源码编译：Release 落后于主分支（gvisor TUN 等改动只在源码里）。
install_proxyd_source() {
  info "从源码编译 proxyd"
  pkg go git make
  local dir="$SRC_DIR/proxyd"
  git_sync "$PROXYD_REPO" "$dir"
  # Web 产物 internal/api/dist 已提交在仓库里，只需 Go 构建；
  # 不用 `make`（会执行 npm run build，新克隆没有 node_modules 会失败）
  make -C "$dir" build
  sudo install -m 0755 "$dir/bin/proxyd" "$PROXYD_BIN"
}

install_proxyd_release() {
  local arch
  case "$(uname -m)" in
    x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) return 1 ;;
  esac
  info "从 GitHub Releases 下载 proxyd（linux/$arch）"
  local api url tmp
  api="$(curl -fsSL "https://api.github.com/repos/$PROXYD_GH/releases/latest")" || return 1
  url="$(grep -oE '"browser_download_url": *"[^"]+"' <<<"$api" | cut -d'"' -f4 \
        | grep -E "_linux_${arch}\.tar\.gz$" | head -n1)"
  [[ -n "$url" ]] || return 1

  tmp="$(mktemp -d)"
  curl -fL --retry 3 -o "$tmp/pkg.tar.gz" "$url" || { rm -rf "$tmp"; return 1; }
  mkdir -p "$tmp/x" && tar -xzf "$tmp/pkg.tar.gz" -C "$tmp/x"
  local bin; bin="$(find "$tmp/x" -type f -name proxyd | head -n1)"
  [[ -n "$bin" ]] || { rm -rf "$tmp"; return 1; }
  sudo install -m 0755 "$bin" "$PROXYD_BIN"
  rm -rf "$tmp"
}

# 清理旧版脚本留下的 user 级自启和 ~/.local/bin 里的旧二进制
cleanup_proxyd_user_mode() {
  local unit="$HOME/.config/systemd/user/proxyd.service"
  if [[ -f "$unit" ]]; then
    systemctl --user disable --now proxyd.service >/dev/null 2>&1 || true
    rm -f "$unit"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    ok "已移除旧的 user 级 proxyd.service"
  fi
  if [[ -x "$BIN_DIR/proxyd" && "$BIN_DIR/proxyd" != "$PROXYD_BIN" ]]; then
    "$BIN_DIR/proxyd" stop >/dev/null 2>&1 || true
    rm -f "$BIN_DIR/proxyd"
    ok "已移除旧二进制 $BIN_DIR/proxyd（现使用 $PROXYD_BIN）"
  fi
}

write_proxyd_config() {
  local node="${PROXY_SCHEME}://${PROXY_HOST}:${PROXY_PORT}#${PROXY_NODE_NAME}"
  sudo mkdir -p "$(dirname "$PROXYD_CONF")"

  if ! sudo test -f "$PROXYD_CONF"; then
    sudo tee "$PROXYD_CONF" >/dev/null <<EOF
# 由 omarchy-init.sh 生成，完整字段见仓库 configs/config.example.yaml
mode: rule
manual-nodes:
  - ${node}
tun:
  enable: true
  stack: gvisor
EOF
    ok "已创建 $PROXYD_CONF，默认节点 $node，TUN(gvisor) 已开启"
  elif sudo grep -qF "${PROXY_HOST}:${PROXY_PORT}" "$PROXYD_CONF"; then
    ok "配置中已存在节点 ${PROXY_HOST}:${PROXY_PORT}"
  else
    sudo cp "$PROXYD_CONF" "$PROXYD_CONF.bak-$TS"
    if sudo grep -qE '^manual-nodes:[[:space:]]*$' "$PROXYD_CONF"; then
      sudo sed -i "/^manual-nodes:[[:space:]]*$/a\\  - ${node}" "$PROXYD_CONF"
    else
      printf '\nmanual-nodes:\n  - %s\n' "$node" | sudo tee -a "$PROXYD_CONF" >/dev/null
    fi
    ok "已追加节点 $node（原配置备份为 $PROXYD_CONF.bak-$TS）"
  fi
}

write_proxyd_unit() {
  sudo tee "$PROXYD_UNIT" >/dev/null <<EOF
[Unit]
Description=proxyd — multi-node port-mapping proxy
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Environment=HOME=/root
ExecStart=${PROXYD_BIN} serve -c ${PROXYD_CONF}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
}

setup_proxyd() {
  info "[3/5] 安装 proxyd 代理工具（root + TUN，系统级服务）"

  if [[ -x "$PROXYD_BIN" && "${PROXYD_REINSTALL:-0}" != 1 ]]; then
    ok "proxyd 已安装：$PROXYD_BIN（设置 PROXYD_REINSTALL=1 可重装）"
  elif [[ "${PROXYD_FROM_RELEASE:-0}" == 1 ]]; then
    install_proxyd_release || { warn "预编译包不可用，改为源码编译"; install_proxyd_source; }
    ok "proxyd 已安装到 $PROXYD_BIN"
  else
    install_proxyd_source || { warn "源码编译失败，改用预编译包（可能不含最新改动）"; install_proxyd_release; }
    ok "proxyd 已安装到 $PROXYD_BIN"
  fi

  cleanup_proxyd_user_mode
  write_proxyd_config
  sudo "$PROXYD_BIN" check -c "$PROXYD_CONF" >/dev/null 2>&1 \
    || warn "proxyd check 未通过，可手动运行 'sudo $PROXYD_BIN check -c $PROXYD_CONF' 查看原因"

  # 停掉手动以 root 启动的实例（sudo proxyd start/serve），避免与服务抢端口
  if ! systemctl is-active --quiet proxyd.service; then
    sudo "$PROXYD_BIN" stop -c "$PROXYD_CONF" >/dev/null 2>&1 || true
    sudo pkill -x proxyd >/dev/null 2>&1 || true
  fi

  write_proxyd_unit
  sudo systemctl enable proxyd.service >/dev/null
  sudo systemctl restart proxyd.service \
    || warn "proxyd 启动失败，查看 'sudo journalctl -u proxyd -e'"
  systemctl is-active --quiet proxyd.service && ok "proxyd.service 已运行并设为开机自启"

  ok "proxyd 就绪，Web 控制台：http://127.0.0.1:19091/"
}

# ============================ 4. SSH =========================================
setup_ssh() {
  info "[4/5] 安装并启用 SSH 服务"
  pkg openssh

  # 生成本机 SSH 密钥（已有则跳过），用于连接 GitHub 等
  if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -N "" -C "$USER@$(hostname)" -f "$HOME/.ssh/id_ed25519" -q
    ok "已生成密钥 ~/.ssh/id_ed25519（公钥：~/.ssh/id_ed25519.pub）"
  fi
  touch "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys"

  sudo systemctl enable --now sshd
  systemctl is-active --quiet sshd && ok "sshd 已运行并设为开机自启（端口 22）"

  # Omarchy 默认启用 ufw 防火墙，需要放行 22 端口
  if have ufw && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    sudo ufw allow 22/tcp >/dev/null && ok "ufw 已放行 22/tcp"
  fi
}

# ============================ 5. 输入法 ======================================
# fcitx5-chinese-addons 自带双拼（shuangpin），与全拼共用词库和用户词频。
# 输入法列表：英文键盘 → 双拼（默认）→ 全拼；Ctrl+Space 中英切换，Ctrl+Shift 轮换。
setup_ime() {
  info "[5/5] 配置 fcitx5 双拼输入法（方案：$SHUANGPIN_PROFILE）"
  pkg fcitx5 fcitx5-chinese-addons fcitx5-gtk fcitx5-qt

  local dir="$HOME/.config/fcitx5"
  local profile="$dir/profile" pinyin="$dir/conf/pinyin.conf"
  mkdir -p "$dir/conf"

  # fcitx5 退出时会把内存中的配置写回 profile，必须先停掉再改
  local was_running=0
  if pgrep -x fcitx5 >/dev/null; then
    was_running=1
    pkill -x fcitx5 || true
    for _ in $(seq 25); do pgrep -x fcitx5 >/dev/null || break; sleep 0.2; done
  fi

  if [[ -f "$profile" ]] && grep -qx 'Name=shuangpin' "$profile" && grep -qx 'DefaultIM=shuangpin' "$profile"; then
    ok "输入法列表中已有双拼"
  else
    [[ -f "$profile" ]] && cp "$profile" "$profile.bak-$TS"
    cat >"$profile" <<'EOF'
[Groups/0]
# Group Name
Name=Default
# Layout
Default Layout=us
# Default Input Method
DefaultIM=shuangpin

[Groups/0/Items/0]
# Name
Name=keyboard-us
# Layout
# Layout=

[Groups/0/Items/1]
# Name
Name=shuangpin
# Layout
# Layout=

[Groups/0/Items/2]
# Name
Name=pinyin
# Layout
# Layout=

[GroupOrder]
0=Default
EOF
    ok "已写入 $profile（英文 / 双拼 / 全拼）"
  fi

  touch "$pinyin"
  if grep -qx "ShuangpinProfile=$SHUANGPIN_PROFILE" "$pinyin"; then
    ok "双拼方案已是 $SHUANGPIN_PROFILE"
  else
    cp "$pinyin" "$pinyin.bak-$TS"
    if grep -qE '^#? *ShuangpinProfile=' "$pinyin"; then
      sed -i -E "s/^#? *ShuangpinProfile=.*/ShuangpinProfile=$SHUANGPIN_PROFILE/" "$pinyin"
    else
      printf 'ShuangpinProfile=%s\n' "$SHUANGPIN_PROFILE" >>"$pinyin"
    fi
    ok "双拼方案设为 $SHUANGPIN_PROFILE"
  fi

  # 原本在运行（图形会话里）才重新拉起；在 TTY 里执行则等下次登录自动启动
  if ((was_running)) && [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    setsid -f fcitx5 --replace --disable notificationitem >/dev/null 2>&1 || true
    ok "fcitx5 已重启"
  fi
}

# ============================ 入口 ===========================================
main() {
  local steps=("$@")
  ((${#steps[@]})) || steps=(nvim fish proxyd ssh ime)

  preflight
  for s in "${steps[@]}"; do
    case "$s" in
      nvim)   setup_nvim ;;
      fish)   setup_fish ;;
      proxyd) setup_proxyd ;;
      ssh)    setup_ssh ;;
      ime)    setup_ime ;;
      *)      die "未知步骤：$s（可选：nvim fish proxyd ssh ime）" ;;
    esac
  done

  echo
  ok "全部完成。请注销并重新登录，让 fish 成为默认 shell。"
}

main "$@"
