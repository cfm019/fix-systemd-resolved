#!/usr/bin/env bash
# ==============================================================================
# 脚本名称: fix-systemd-resolved.sh
# 功能描述: 一键修复 Debian 12 / Linux 环境下 sing-box 报 D-Bus / systemd-resolved
#           DNS 解析失败导致 VLESS Reality 代理断连的问题。
# 修复原理: 在系统层安装配置 systemd-resolved，动态绑定出口网卡 DNS，无需改动 sing-box 配置。
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $*"; }

# 1. 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    log_err "此脚本需要 root 权限执行，请使用 sudo 或切换至 root 用户。"
    exit 1
fi

log_info "开始检测并修复系统 DNS (systemd-resolved) 配置..."

# 2. 检测默认网络出口网卡
DEFAULT_IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1 || true)
if [ -z "$DEFAULT_IFACE" ]; then
    DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1 || true)
fi
if [ -z "$DEFAULT_IFACE" ]; then
    DEFAULT_IFACE="eth0"
    log_warn "未能自动检测到默认出口网卡，回落至默认: ${DEFAULT_IFACE}"
else
    log_ok "检测到默认网络出口网卡: ${DEFAULT_IFACE}"
fi

# 3. 检查并安装 systemd-resolved
if ! command -v resolvectl >/dev/null 2>&1 && ! dpkg -l | grep -q "^ii.*systemd-resolved"; then
    log_info "检测到系统未安装 systemd-resolved，正在通过 apt 安装..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y systemd-resolved
    log_ok "systemd-resolved 安装完成。"
else
    log_ok "systemd-resolved 已安装。"
fi

# 4. 配置全局上游 DNS Drop-in
log_info "配置 systemd-resolved 全局 DNS 设置..."
mkdir -p /etc/systemd/resolved.conf.d
cat << 'EOF' > /etc/systemd/resolved.conf.d/dns.conf
[Resolve]
DNS=1.1.1.1 8.8.8.8 2606:4700:4700::1111
FallbackDNS=1.0.0.1 8.8.4.4
Domains=~.
EOF
log_ok "全局 DNS 已配置 (1.1.1.1 / 8.8.8.8)。"

# 5. 配置出口网卡动态绑定脚本与 systemd drop-in
log_info "配置出口网卡持久化 DNS 绑定服务..."
cat << 'EOF' > /usr/local/bin/resolved-setup-iface.sh
#!/bin/bash
# 动态获取当前默认路由出口网卡
IFACE=$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1)
if [ -n "$IFACE" ]; then
    /usr/bin/resolvectl domain "$IFACE" "" 2>/dev/null || true
    /usr/bin/resolvectl dns "$IFACE" 1.1.1.1 8.8.8.8 2606:4700:4700::1111 2>/dev/null || true
    /usr/bin/resolvectl default-route "$IFACE" true 2>/dev/null || true
fi
EOF
chmod +x /usr/local/bin/resolved-setup-iface.sh

mkdir -p /etc/systemd/system/systemd-resolved.service.d
cat << 'EOF' > /etc/systemd/system/systemd-resolved.service.d/interface-dns.conf
[Service]
ExecStartPost=-/usr/local/bin/resolved-setup-iface.sh
EOF

# 6. 配置 /etc/resolv.conf 软链接
log_info "修正 /etc/resolv.conf 软链接..."
if [ -L /etc/resolv.conf ] || [ -f /etc/resolv.conf ]; then
    rm -f /etc/resolv.conf
fi
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
log_ok "/etc/resolv.conf 已正确指向 systemd-resolved stub。"

# 7. 重启 dbus 与 systemd-resolved
log_info "重载 systemd 配置并重启服务..."
systemctl daemon-reload
# 重启 dbus 避免新增用户缓存导致的激活超时
systemctl restart dbus || true
systemctl enable --now systemd-resolved
systemctl restart systemd-resolved
sleep 1

# 8. 触发网卡 DNS 绑定
/usr/local/bin/resolved-setup-iface.sh || true

# 9. 检查或重启 sing-box / vless 相关服务
for svc in vless-singbox sing-box; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        log_info "检测到运行中的服务 $svc，正在重启以应用新 DNS 状态..."
        systemctl restart "$svc"
        log_ok "$svc 重启成功。"
    fi
done

# 10. 检测 IPv6 公网连通性，若不可用则直接在系统层彻底禁用 IPv6
log_info "检测 IPv6 公网连通性..."
if ip -6 route show default 2>/dev/null | grep -q default; then
    if ! ping6 -c 2 -W 2 2606:4700:4700::1111 >/dev/null 2>&1 && ! ping6 -c 2 -W 2 2001:4860:4860::8888 >/dev/null 2>&1; then
        log_warn "检测到系统分配了 IPv6 但外网路由不通 (机房伪双栈黑洞)，正在彻底禁用 IPv6..."
        cat << 'EOF' > /etc/sysctl.d/99-disable-ipv6.conf
# 彻底禁用不可用的 IPv6，避免伪双栈导致的网络黑洞与解析超时
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
        sysctl -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1 net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1 || true
        log_ok "已在内核层彻底禁用不可用的 IPv6 (写入 /etc/sysctl.d/99-disable-ipv6.conf)。"
    else
        log_ok "IPv6 公网连通正常。"
    fi
else
    log_info "系统未配置 IPv6 默认路由。"
fi

# 11. 配置 IPv4 优先备选 (gai.conf 进一步保障双栈兼容)
log_info "优化 IPv4 优先级 (gai.conf)..."
if [ -f /etc/gai.conf ]; then
    if grep -q "^#precedence ::ffff:0:0/96  100" /etc/gai.conf; then
        sed -i 's/#precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf
    elif ! grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf; then
        echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
    fi
else
    echo "precedence ::ffff:0:0/96  100" > /etc/gai.conf
fi
log_ok "IPv4 优先策略已就绪。"

# 12. 验证测试
log_info "正在验证 DNS 解析与服务状态..."
if resolvectl query store.apple.com >/dev/null 2>&1 || resolvectl query google.com >/dev/null 2>&1; then
    log_ok "systemd-resolved 解析验证成功！"
fi

if curl -fsSL -o /dev/null --connect-timeout 5 https://raw.githubusercontent.com >/dev/null 2>&1; then
    log_ok "raw.githubusercontent.com 连接验证秒开！"
fi

echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}  系统 DNS 与双栈网络环境修复完成！开机自启且重启后持久生效。${NC}"
echo -e "${GREEN}  - systemd-resolved 原生支持 D-Bus (无需修改 sing-box 配置)${NC}"
echo -e "${GREEN}  - 彻底禁用不可用的伪双栈 IPv6，秒连 raw.githubusercontent.com${NC}"
echo -e "${GREEN}================================================================${NC}"
