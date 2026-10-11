# fix-systemd-resolved

Linux / Debian 12 VPS 网络与 DNS 一键修复工具。彻底解决 **sing-box VLESS Reality 代理断连** 与 **机房伪双栈 IPv6 路由黑洞导致 raw.githubusercontent.com 40秒超时** 的问题。

---

## 🚀 一键运行

在 VPS 终端以 `root` 权限执行以下命令：

```bash
curl -fsSL https://raw.githubusercontent.com/cfm019/fix-systemd-resolved/main/fix-systemd-resolved.sh | bash
```

> **备用加速镜像（国内机房/网络不佳时）：**
> ```bash
> curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/cfm019/fix-systemd-resolved/main/fix-systemd-resolved.sh | bash
> ```

### 通过 bwssh 远程批量推送执行
如果在本地配置了 `bwssh`，可直接通过管道将本地脚本推送到远程目标机器：
```bash
~/.local/bin/bwssh <server-alias> 'bash -s' < fix-systemd-resolved.sh
```

---

## 🎯 解决的核心痛点

### 1. sing-box (VLESS Reality) 报 D-Bus 找不到服务
* **错误表现**：
  ```text
  ERROR inbound/vless[...]: TLS handshake: REALITY: failed to dial dest: lookup store.apple.com: 
  (exchange4: The name org.freedesktop.resolve1 was not provided by any .service files | 
   exchange6: The name org.freedesktop.resolve1 was not provided by any .service files)
  ```
* **根本原因**：Debian 12 默认将 `systemd-resolved` 独立拆包，最小化安装未自带该组件，但系统运行了 `dbus`；静态编译的 `sing-box` 在未手动指定 DNS 时默认通过 D-Bus 请求 `org.freedesktop.resolve1` 解析伪装域名，因缺失服务导致域名解析全部失败，Reality 握手被直接 Reset（errno 104）。
* **本工具解法**：系统层补齐 `systemd-resolved` 并配置 D-Bus 接口，**无需改动任何 sing-box 配置文件**。

### 2. 出口链路未配置 DNS 报错
* **错误表现**：
  ```text
  (exchange4: link has no DNS servers configured | exchange6: link has no DNS servers configured)
  ```
* **根本原因**：部分云厂商系统模板（cloud-init）将 DNS 错误写在 `lo`（回环）网卡上，系统网络钩子忽略了 `lo`，导致物理网卡 `eth0` 没有任何关联的上游 DNS。
* **本工具解法**：通过 systemd drop-in 启动钩子，开机自动识别当前默认路由出口网卡（自适应 `eth0`、`ens3`、`enp1s0` 等），持久化绑定 DNS 与 DefaultRoute。

### 3. 机房“伪双栈”IPv6 路由黑洞导致 `raw.githubusercontent.com` 40 秒超时
* **错误表现**：`curl https://raw.githubusercontent.com/...` 报 `Connection timed out`，或等待 40 秒才开始下载；但访问 `github.com` 却秒开。
* **根本原因**：机房分配了公网 IPv6 地址和网关，但外网 IPv6 路由根本不通；Linux glibc（RFC 6724）检测到本机有公网 IPv6，强制将 Fastly CDN 的 4 个 IPv6 地址排在 IPv4 前面，连续对黑洞发送 TCP SYN 超时（每个约 20 秒），导致严重卡顿。
* **本工具解法**：自动探测 IPv6 外网连通性，一旦发现机房分配了死 IPv6，直接在内核层（`/etc/sysctl.d/99-disable-ipv6.conf`）彻底禁用 IPv6，同时优化 `/etc/gai.conf`，将访问耗时从 **40 秒** 降至 **0.1 秒**。

---

## 🛠️ 脚本执行流程

1. **自动检测出口网卡**：动态识别当前主路由网络接口（`eth0` / `ens3` / `enp1s0` / `ens18` 等）。
2. **安装并启用 `systemd-resolved`**：通过非交互式 apt 补齐缺失组件。
3. **全局 DNS 配置**：配置 `1.1.1.1`、`8.8.8.8` 并开启 `Domains=~.`。
4. **动态网卡持久化绑定**：写入 `/usr/local/bin/resolved-setup-iface.sh` 与 systemd drop-in，每次启动自动绑定。
5. **修正软链接**：将 `/etc/resolv.conf` 正确链接至 `/run/systemd/resolve/stub-resolv.conf`（`127.0.0.53`）。
6. **重启相关服务**：重启 `dbus`、`systemd-resolved`，若检测到 `vless-singbox` 或 `sing-box` 会自动安全重启应用。
7. **探测并处理 IPv6 黑洞**：若 IPv6 外网不通，在内核层彻底禁用 IPv6；优化 `gai.conf` 优先解析 IPv4。
8. **自动连通性验证**：测试 `systemd-resolved` 解析及 `raw.githubusercontent.com` 秒开验证。

---

## 🔍 验证与排查命令

执行脚本后，可在服务器上运行以下命令确认状态：

```bash
# 1. 检查 DNS 解析状态与链路绑定
resolvectl status

# 2. 测试域名解析
resolvectl query store.apple.com

# 3. 验证 raw.githubusercontent.com 连通速度（秒开）
curl -s -o /dev/null -w 'HTTP Code: %{http_code}, Time: %{time_total}s\n' https://raw.githubusercontent.com

# 4. 检查 sing-box 服务状态
systemctl status vless-singbox --no-pager
```

---

## 📋 适用系统

* Debian 12 (Bookworm) / Debian 11 (Bullseye)
* Ubuntu 20.04 / 22.04 / 24.04
* 其他基于 systemd 的 Linux 发行版

---

## 📄 开源许可

MIT License
