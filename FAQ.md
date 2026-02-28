# VLESS-Server 故障排查指南 (FAQ)

本文档提供完整的故障排查命令和预期输出，帮助诊断各种问题。

---

## 目录 
 
1. [服务状态检查](#1-服务状态检查)
2. [Xray 核心排查](#2-xray-核心排查)
3. [Sing-box 核心排查](#3-sing-box-核心排查)
4. [独立协议排查](#4-独立协议排查)
5. [证书排查](#5-证书排查)
6. [Nginx 排查](#6-nginx-排查)
7. [端口与防火墙排查](#7-端口与防火墙排查)
8. [端口跳跃排查](#8-端口跳跃排查)
9. [订阅服务排查](#9-订阅服务排查)
10. [Telegram 通知排查](#10-telegram-通知排查)
11. [数据库排查](#11-数据库排查)
12. [用户与流量统计排查](#12-用户与流量统计排查)
13. [日志查看](#13-日志查看)
14. [WARP 分流排查](#14-warp-分流排查)
15. [分流路由规则排查](#15-分流路由规则排查)
16. [定时任务排查](#16-定时任务排查)
17. [CF Tunnel 排查](#17-cf-tunnel-排查)
18. [系统优化排查](#18-系统优化排查)
19. [备份与恢复](#19-备份与恢复)
20. [常见问题](#20-常见问题)

---

## 1. 服务状态检查

### 1.1 查看所有 vless 相关服务状态

```bash
# systemd 系统 (Debian/Ubuntu/CentOS)
systemctl list-units --type=service | grep vless

# OpenRC 系统 (Alpine)
rc-status | grep vless
```

**正常输出示例：**
```
vless-reality.service    loaded active running   Xray Core Service
vless-singbox.service    loaded active running   Sing-box Service
vless-snell.service      loaded active running   Snell Server
```

### 1.2 单个服务状态检查

```bash
# Xray 服务
systemctl status vless-reality

# Sing-box 服务
systemctl status vless-singbox

# Snell 服务
systemctl status vless-snell
systemctl status vless-snell-v5

# ShadowTLS 服务
systemctl status vless-snell-shadowtls
systemctl status vless-ss2022-shadowtls

# AnyTLS 服务
systemctl status vless-anytls

# NaïveProxy 服务
systemctl status vless-naive
```

**正常输出：** `Active: active (running)`

---

## 2. Xray 核心排查

### 2.1 检查 Xray 是否运行

```bash
pgrep -x xray && echo "Xray 运行中" || echo "Xray 未运行"
```

**正常输出：** `Xray 运行中`

### 2.2 检查 Xray 版本

```bash
/usr/local/bin/xray version
```

**正常输出示例：**
```
Xray 1.8.24 (Xray, Penetrates Everything.) Custom (go1.22.0 linux/amd64)
```

### 2.3 检查 Xray 配置文件

```bash
# 查看配置文件
cat /etc/vless-reality/config.json | jq .

# 检查配置语法
/usr/local/bin/xray run -test -c /etc/vless-reality/config.json
```

**正常输出：** `Configuration OK.`

### 2.4 检查 Xray 监听端口

```bash
# 查看 Xray 监听的端口
cat /etc/vless-reality/config.json | jq '.inbounds[].port'

# 验证端口是否在监听
ss -tlnp | grep xray
```

### 2.5 检查 Xray 入站配置

```bash
# 列出所有入站协议
cat /etc/vless-reality/config.json | jq '.inbounds[] | {tag: .tag, port: .port, protocol: .protocol}'
```

**正常输出示例：**
```json
{"tag": "vless-reality-in", "port": 443, "protocol": "vless"}
{"tag": "vless-ws-in", "port": 8080, "protocol": "vless"}
{"tag": "trojan-in", "port": 443, "protocol": "trojan"}
```

### 2.6 检查 Xray 流量统计配置

```bash
# 检查是否启用流量统计
cat /etc/vless-reality/config.json | jq '.stats'
```

**正常输出：** `{}` (空对象表示已启用)

---

## 3. Sing-box 核心排查

### 3.1 检查 Sing-box 是否运行

```bash
pgrep -x sing-box && echo "Sing-box 运行中" || echo "Sing-box 未运行"
```

### 3.2 检查 Sing-box 版本

```bash
/usr/local/bin/sing-box version
```

**正常输出示例：**
```
sing-box version 1.8.0
```

### 3.3 检查 Sing-box 配置文件

```bash
# 查看配置
cat /etc/vless-reality/singbox.json | jq .

# 验证配置语法
/usr/local/bin/sing-box check -c /etc/vless-reality/singbox.json
```

**正常输出：** 无输出表示配置正确

### 3.4 检查 Sing-box 入站配置

```bash
cat /etc/vless-reality/singbox.json | jq '.inbounds[] | {tag: .tag, type: .type, listen_port: .listen_port}'
```

**正常输出示例：**
```json
{"tag": "hy2-in", "type": "hysteria2", "listen_port": 8443}
{"tag": "tuic-in", "type": "tuic", "listen_port": 8444}
```

---

## 4. 独立协议排查

### 4.1 Snell 服务

```bash
# 检查进程
pgrep -f snell-server && echo "Snell 运行中" || echo "Snell 未运行"

# 查看配置
cat /etc/vless-reality/snell.conf

# Snell v5
cat /etc/vless-reality/snell-v5.conf
```

**正常配置示例：**
```ini
[snell-server]
listen = 0.0.0.0:8388
psk = your_psk_here
version = 4
```

### 4.2 ShadowTLS 服务

```bash
# 检查主进程
pgrep -f shadow-tls && echo "ShadowTLS 运行中" || echo "ShadowTLS 未运行"

# 检查后端服务
systemctl status vless-snell-shadowtls-backend
systemctl status vless-ss2022-shadowtls-backend
```

### 4.3 AnyTLS 服务

```bash
# 检查进程
pgrep -f anytls-server && echo "AnyTLS 运行中" || echo "AnyTLS 未运行"

# 查看配置 (从数据库)
cat /etc/vless-reality/db.json | jq '.standalone.anytls'
```

### 4.4 NaïveProxy 服务

```bash
# 检查 Caddy 进程
pgrep -f caddy && echo "NaïveProxy 运行中" || echo "NaïveProxy 未运行"

# 查看 Caddyfile
cat /etc/vless-reality/Caddyfile
```

---

## 5. 证书排查

### 5.1 检查证书文件

```bash
# 检查证书是否存在
ls -la /etc/vless-reality/certs/

# 检查证书有效期
openssl x509 -in /etc/vless-reality/certs/server.crt -noout -dates
```

**正常输出：**
```
-rw-r--r-- 1 root root 1234 Jan 01 00:00 server.crt
-rw------- 1 root root 1234 Jan 01 00:00 server.key
```

### 5.2 检查证书是否过期

```bash
# 检查是否在30天内过期
openssl x509 -in /etc/vless-reality/certs/server.crt -noout -checkend 2592000 && echo "证书有效" || echo "证书即将过期或已过期"
```

### 5.3 检查证书域名

```bash
cat /etc/vless-reality/cert_domain
```

### 5.4 检查证书颁发者 (CA 还是自签名)

```bash
openssl x509 -in /etc/vless-reality/certs/server.crt -noout -issuer
```

**真实证书输出示例：**
```
issuer=C = US, O = Let's Encrypt, CN = R3
```

**自签名证书输出示例：**
```
issuer=CN = your-domain.com
```

### 5.5 检查 ACME 证书续期

```bash
# 检查 acme.sh 是否安装
~/.acme.sh/acme.sh --version

# 列出所有证书
~/.acme.sh/acme.sh --list

# 手动续期
~/.acme.sh/acme.sh --renew -d your-domain.com --force
```

---

## 6. Nginx 排查

### 6.1 检查 Nginx 状态

```bash
# 服务状态
systemctl status nginx

# 进程检查
pgrep nginx && echo "Nginx 运行中" || echo "Nginx 未运行"
```

### 6.2 检查 Nginx 配置

```bash
# 测试配置语法
nginx -t

# 查看订阅配置
cat /etc/nginx/sites-enabled/vless-sub.conf 2>/dev/null || \
cat /etc/nginx/conf.d/vless-sub.conf 2>/dev/null || \
cat /etc/nginx/http.d/vless-sub.conf 2>/dev/null
```

**正常输出：** `nginx: configuration file /etc/nginx/nginx.conf test is successful`

### 6.3 检查 Nginx 监听端口

```bash
ss -tlnp | grep nginx
```

**正常输出示例：**
```
LISTEN 0 511 *:80 *:* users:(("nginx",pid=1234,fd=6))
LISTEN 0 511 *:8443 *:* users:(("nginx",pid=1234,fd=7))
```

### 6.4 检查订阅文件

```bash
# 检查订阅目录
ls -la /etc/vless-reality/sub/

# 检查订阅内容
cat /etc/vless-reality/sub/default.txt
```

---

## 7. 端口与防火墙排查

### 7.1 检查端口是否被占用

```bash
# 检查特定端口
ss -tlnp | grep :443
ss -ulnp | grep :443  # UDP 端口 (Hysteria2/TUIC)

# 查看所有监听端口
ss -tlnp
```

### 7.2 检查防火墙规则

```bash
# iptables
iptables -L -n -v
iptables -t nat -L -n -v

# nftables
nft list ruleset

# firewalld
firewall-cmd --list-all

# ufw
ufw status verbose
```

### 7.3 测试端口连通性

```bash
# 本地测试
nc -zv 127.0.0.1 443

# 远程测试 (从其他机器)
nc -zv your-server-ip 443
```

---

## 8. 端口跳跃排查

### 8.1 检查端口跳跃 iptables 规则

```bash
# 查看 NAT 规则
iptables -t nat -L PREROUTING -n -v | grep -E "dpt:|dports"

# 查看端口跳跃规则
iptables -t nat -L PREROUTING -n -v --line-numbers
```

**正常输出示例 (Hysteria2 端口跳跃 20000-50000 → 8443)：**
```
Chain PREROUTING (policy ACCEPT)
num   target     prot opt source   destination
1     REDIRECT   udp  --  0.0.0.0/0  0.0.0.0/0  udp dpts:20000:50000 redir ports 8443
```

### 8.2 检查端口跳跃配置

```bash
# 查看数据库中的端口跳跃配置
cat /etc/vless-reality/db.json | jq '.singbox.hy2.hop_enable, .singbox.hy2.hop_start, .singbox.hy2.hop_end'
```

**正常输出：**
```
1
20000
50000
```

### 8.3 验证端口跳跃是否生效

```bash
# 测试跳跃范围内的端口 (应该被重定向)
nc -u -zv your-server-ip 30000

# 使用 tcpdump 监控
tcpdump -i any udp port 8443 -n
```

### 8.4 手动添加端口跳跃规则

```bash
# 添加规则 (UDP 20000-50000 → 8443)
iptables -t nat -A PREROUTING -p udp --dport 20000:50000 -j REDIRECT --to-ports 8443

# 保存规则
iptables-save > /etc/iptables/rules.v4
```

### 8.5 删除端口跳跃规则

```bash
# 查看规则行号
iptables -t nat -L PREROUTING -n -v --line-numbers

# 删除指定规则 (假设行号为 1)
iptables -t nat -D PREROUTING 1
```

---

## 9. 订阅服务排查

### 9.1 检查订阅配置

```bash
# 查看订阅信息
cat /etc/vless-reality/sub.info
```

**正常输出示例：**
```
sub_domain="your-domain.com"
sub_port="8443"
sub_token="your_secret_token"
```

### 9.2 测试订阅 URL

```bash
# 本地测试
curl -k https://localhost:8443/sub/your_token

# 外部测试
curl -k "https://your-domain.com:8443/sub/your_token"
```

**正常输出：** Base64 编码的订阅内容

### 9.3 解码订阅内容

```bash
curl -sk "https://your-domain.com:8443/sub/your_token" | base64 -d
```

---

## 10. Telegram 通知排查

### 10.1 检查 TG 配置文件

```bash
cat /etc/vless-reality/telegram.json | jq .
```

**正常输出示例：**
```json
{
  "bot_token": "123456:ABC...",
  "chat_id": "-100123456789",
  "enabled": true,
  "last_report_date": "2024-01-15"
}
```

### 10.2 检查 Xray 是否运行 (TG 通知依赖)

```bash
pgrep -x xray && echo "Xray 运行中" || echo "Xray 未运行"
```

### 10.3 手动测试每日报告

```bash
/root/vless-server.sh --sync-traffic
echo "执行完成, 检查 TG"
```

### 10.4 检查发送记录

```bash
cat /etc/vless-reality/telegram.json | jq -r '.last_report_date // "从未发送"'
```

### 10.5 手动发送测试消息

```bash
# 提取配置
BOT_TOKEN=$(cat /etc/vless-reality/telegram.json | jq -r '.bot_token')
CHAT_ID=$(cat /etc/vless-reality/telegram.json | jq -r '.chat_id')

# 发送测试消息
curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -d chat_id="${CHAT_ID}" \
  -d text="测试消息"
```

**正常输出：** `{"ok":true,...}`

---

## 11. 数据库排查

### 11.1 查看完整数据库

```bash
cat /etc/vless-reality/db.json | jq .
```

### 11.2 查看已安装的协议

```bash
# Xray 协议
cat /etc/vless-reality/db.json | jq '.xray | keys'

# Sing-box 协议
cat /etc/vless-reality/db.json | jq '.singbox | keys'

# 独立协议
cat /etc/vless-reality/db.json | jq '.standalone | keys'
```

### 11.3 查看特定协议配置

```bash
# VLESS Reality
cat /etc/vless-reality/db.json | jq '.xray.vless'

# Hysteria2
cat /etc/vless-reality/db.json | jq '.singbox.hy2'

# Trojan
cat /etc/vless-reality/db.json | jq '.xray.trojan'

# Trojan-WS
cat /etc/vless-reality/db.json | jq '.xray["trojan-ws"]'
```

### 11.4 查看用户列表

```bash
cat /etc/vless-reality/db.json | jq '.users'
```

---

## 12. 用户与流量统计排查

### 12.1 查看 Xray 流量统计 API

```bash
# 检查 API 端口
cat /etc/vless-reality/config.json | jq '.api'

# 手动查询流量 (gRPC)
# 需要 grpcurl 工具
grpcurl -plaintext 127.0.0.1:10085 xray.app.stats.command.StatsService/QueryStats
```

### 12.2 同步流量数据

```bash
/root/vless-server.sh --sync-traffic
```

### 12.3 查看用户流量记录

```bash
cat /etc/vless-reality/db.json | jq '.users[] | {name: .name, upload: .upload, download: .download}'
```

### 12.4 用户到期日期排查

```bash
# 查看用户到期日期
cat /etc/vless-reality/db.json | jq '.. | .users? // empty | .[] | select(.expire_date) | {name, expire_date}'

# 手动检查过期用户
./vless-server.sh --check-expire

# 手动检查并发送 TG 通知
./vless-server.sh --check-expire --notify

# 安装每日自动检查 (每天 3:00)
./vless-server.sh --setup-expire-cron

# 查看过期检查日志
cat /etc/vless-reality/expire.log

# 查看过期检查 cron
crontab -l | grep check-expire
```

**正常输出示例：**
```
检查用户到期状态...
  即将过期提醒: 1 条
  禁用过期用户: 0 个
完成。日志: /etc/vless-reality/expire.log
```

---

## 13. 日志查看

### 13.1 Xray 日志

```bash
# systemd
journalctl -u vless-reality -f

# 查看最近 100 行
journalctl -u vless-reality -n 100

# 查看错误日志
journalctl -u vless-reality -p err
```

### 13.2 Sing-box 日志

```bash
journalctl -u vless-singbox -f
```

### 13.3 Nginx 日志

```bash
# 访问日志
tail -f /var/log/nginx/access.log

# 错误日志
tail -f /var/log/nginx/error.log
```


### 13.4 独立协议日志

```bash
# Snell
journalctl -u vless-snell -f

# ShadowTLS
journalctl -u vless-snell-shadowtls -f

# AnyTLS
journalctl -u vless-anytls -f
```

### 13.5 Alpine 系统日志 (OpenRC)

```bash
# Xray 日志
tail -f /var/log/vless/xray.log

# Sing-box 日志
tail -f /var/log/vless/singbox.log

# 系统日志
tail -f /var/log/messages | grep -E "xray|sing-box|vless"
```

### 13.6 开启 Debug 模式排查

默认日志级别只显示 warning，需开启 debug 模式才能看到详细路由信息。

**Xray 开启 debug 模式：**
```bash
# 编辑配置文件
sed -i 's/"loglevel":"warning"/"loglevel":"debug"/' /etc/vless-reality/config.json

# 重启服务
systemctl restart vless-reality    # systemd
rc-service vless-reality restart   # Alpine

# 查看详细日志
journalctl -u vless-reality -f     # systemd
tail -f /var/log/vless/xray.log    # Alpine

# 恢复 warning 级别
sed -i 's/"loglevel":"debug"/"loglevel":"warning"/' /etc/vless-reality/config.json
```

**Sing-box 开启 debug 模式：**
```bash
# 编辑配置文件
sed -i 's/"level":"warn"/"level":"debug"/' /etc/vless-reality/singbox.json

# 重启服务
systemctl restart vless-singbox    # systemd
rc-service vless-singbox restart   # Alpine

# 查看详细日志
journalctl -u vless-singbox -f     # systemd
tail -f /var/log/vless/singbox.log # Alpine

# 恢复 warn 级别
sed -i 's/"level":"debug"/"level":"warn"/' /etc/vless-reality/singbox.json
```

### 13.7 用户路由排查

**检查用户路由配置：**
```bash
# Xray 用户路由规则
cat /etc/vless-reality/config.json | jq '.routing.rules[] | select(.user)'

# Sing-box 用户路由规则
cat /etc/vless-reality/singbox.json | jq '.route.rules[] | select(.auth_user)'

# 数据库中的用户路由设置
cat /etc/vless-reality/db.json | jq '.xray | .. | .users? // empty | .[] | {name, routing}'
cat /etc/vless-reality/db.json | jq '.singbox | .. | .users? // empty | .[] | {name, routing}'
```

**检查链式代理 outbound：**
```bash
# Xray 链式代理 outbound
cat /etc/vless-reality/config.json | jq '.outbounds[] | select(.tag | contains("chain"))'

# Sing-box 链式代理 outbound
cat /etc/vless-reality/singbox.json | jq '.outbounds[] | select(.tag | contains("chain"))'
```

**验证路由规则配置正确：**
```bash
# 检查 Xray 配置语法
/usr/local/bin/xray run -test -c /etc/vless-reality/config.json

# 检查 Sing-box 配置语法
/usr/local/bin/sing-box check -c /etc/vless-reality/singbox.json
```


---

## 14. WARP 分流排查

WARP 支持两种模式：WGCF (WireGuard) 和 官方客户端 (SOCKS5)。

### 14.1 检查 WARP 配置模式

```bash
# 查看当前 WARP 模式
cat /etc/vless-reality/db.json | jq -r '.routing.warp_mode // "wgcf"'
```

**输出：** `wgcf` 或 `official`

### 14.2 WGCF 模式排查

```bash
# 检查 wgcf 工具
/usr/local/bin/wgcf --version

# 检查 WARP 配置文件
cat /etc/vless-reality/warp.json | jq .

# 验证 WireGuard 密钥
cat /etc/vless-reality/warp.json | jq '.private_key'
```

**正常配置示例：**
```json
{
  "private_key": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=",
  "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
  "endpoint": "162.159.192.1:2408",
  "reserved": [1, 2, 3],
  "ipv4": "172.16.0.2/32",
  "ipv6": "2606:4700:xxxx::1/128"
}
```

### 14.3 检查 Xray 出站 WARP 配置

```bash
# 查看 Xray 配置中的 WARP 出站
cat /etc/vless-reality/config.json | jq '.outbounds[] | select(.tag | startswith("warp"))'
```

**正常输出示例 (WGCF 模式)：**
```json
{
  "tag": "warp-ipv4",
  "protocol": "wireguard",
  "settings": {
    "secretKey": "...",
    "address": ["172.16.0.2/32"],
    "peers": [{"publicKey": "...", "endpoint": "162.159.192.1:2408"}]
  }
}
```

### 14.4 官方客户端模式排查

```bash
# 检查 warp-cli 是否安装
which warp-cli

# 检查 warp-cli 状态
warp-cli status

# 检查 warp-cli 模式
warp-cli settings

# 检查 SOCKS5 端口监听
ss -tlnp | grep 40000
```

**正常状态输出：**
```
Status: Connected
Mode: Proxy
```

### 14.5 测试 WARP 连接

```bash
# WGCF 模式测试 (通过 WireGuard 接口)
curl -4 --interface wgcf ifconfig.me  # 如果有 wgcf 接口

# 官方客户端模式测试 (通过 SOCKS5 代理)
curl -x socks5://127.0.0.1:40000 https://cloudflare.com/cdn-cgi/trace

# 验证是否使用 Cloudflare IP
curl -x socks5://127.0.0.1:40000 ipinfo.io
```

**正常输出应显示 Cloudflare 相关 IP**

### 14.6 WARP 常见问题

```bash
# 问题：WGCF 无法连接 (UDP 被封锁)
# 解决：切换到官方客户端模式
cat /etc/vless-reality/db.json | jq '.routing.warp_mode'
# 如果是 wgcf，考虑切换到 official 模式

# 问题：官方客户端 UDP 不可用
# 检查：SOCKS5 不支持 UDP，检查路由规则
cat /etc/vless-reality/config.json | jq '.routing.rules[] | select(.network == "udp")'
```

---

## 15. 分流路由规则排查

### 15.1 查看路由配置

```bash
# 查看完整路由配置
cat /etc/vless-reality/config.json | jq '.routing'

# 查看路由规则列表
cat /etc/vless-reality/config.json | jq '.routing.rules'
```

### 15.2 查看数据库中的自定义规则

```bash
# 查看用户定义的规则
cat /etc/vless-reality/db.json | jq '.routing'
```

### 15.3 检查出站配置

```bash
# 列出所有出站
cat /etc/vless-reality/config.json | jq '.outbounds[] | {tag: .tag, protocol: .protocol}'
```

**正常输出示例：**
```json
{"tag": "direct", "protocol": "freedom"}
{"tag": "warp-ipv4", "protocol": "wireguard"}
{"tag": "warp-ipv6", "protocol": "wireguard"}
{"tag": "block", "protocol": "blackhole"}
```

### 15.4 检查域名/IP 分流规则

```bash
# 查看域名规则
cat /etc/vless-reality/config.json | jq '.routing.rules[] | select(.domain)'

# 查看 IP 规则
cat /etc/vless-reality/config.json | jq '.routing.rules[] | select(.ip)'

# 查看 geoip/geosite 规则
cat /etc/vless-reality/config.json | jq '.routing.rules[] | select(.domain | type == "array" and any(startswith("geosite:")))'
```

### 15.5 验证分流生效

```bash
# 查看 Xray 实时日志，观察路由决策
journalctl -u vless-reality -f | grep -E "outbound|routing"
```

---

## 16. 定时任务排查

### 16.1 检查 crontab 任务

```bash
# 查看当前用户的定时任务
crontab -l

# 查看 root 用户的定时任务
sudo crontab -l
```

**正常输出示例：**
```
*/5 * * * * /root/vless-server.sh --sync-traffic >/dev/null 2>&1
0 3 * * * /root/.acme.sh/acme.sh --cron >/dev/null 2>&1
```

### 16.2 检查流量统计定时任务

```bash
# 检查是否配置了流量同步
crontab -l | grep sync-traffic

# 查看流量同步间隔配置
cat /etc/vless-reality/traffic_interval 2>/dev/null || echo "默认5分钟"
```

### 16.3 检查证书自动续期

```bash
# 检查 acme.sh 定时任务
crontab -l | grep acme

# 手动测试续期
~/.acme.sh/acme.sh --cron --force
```

### 16.4 手动触发定时任务

```bash
# 手动同步流量
/root/vless-server.sh --sync-traffic

# 手动续期证书
~/.acme.sh/acme.sh --renew -d your-domain.com --force
```

---

## 17. CF Tunnel 排查

Cloudflare Tunnel 用于 VLESS-WS-CF 协议 (无 TLS 模式)。

### 17.1 检查 cloudflared 进程

```bash
# 检查进程
pgrep -f cloudflared && echo "cloudflared 运行中" || echo "cloudflared 未运行"

# 查看版本
cloudflared --version
```

### 17.2 检查 Tunnel 配置

```bash
# 检查配置目录
ls -la ~/.cloudflared/

# 查看凭证文件
ls ~/.cloudflared/*.json
```

### 17.3 检查 Tunnel 状态

```bash
# 列出 tunnel
cloudflared tunnel list

# 查看 tunnel 详情
cloudflared tunnel info <tunnel-name>
```

### 17.4 检查 VLESS-WS-CF 配置

```bash
# 查看数据库中的 CF 协议配置
cat /etc/vless-reality/db.json | jq '.xray["vless-ws-notls"]'
```

**正常配置示例：**
```json
{
  "uuid": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "port": 8080,
  "path": "/vless",
  "host": "your-tunnel.trycloudflare.com"
}
```

### 17.5 测试 Tunnel 连接

```bash
# 本地测试 (无 TLS)
curl http://localhost:8080/vless -v

# 通过 Tunnel 域名测试
curl https://your-tunnel.trycloudflare.com/vless -v
```

---

## 18. 系统优化排查

### 18.1 检查 BBR 状态

```bash
# 检查当前拥塞控制算法
sysctl net.ipv4.tcp_congestion_control

# 检查可用算法
sysctl net.ipv4.tcp_available_congestion_control

# 检查 BBR 模块
lsmod | grep bbr
```

**正常输出：**
```
net.ipv4.tcp_congestion_control = bbr
```

### 18.2 检查双栈监听配置

```bash
# 检查 IPv6 bindv6only 设置
cat /proc/sys/net/ipv6/bindv6only

# 检查持久化配置
cat /etc/sysctl.d/99-vless-dualstack.conf 2>/dev/null
```

**双栈正常值：** `0` (允许 IPv4 和 IPv6 同时监听)

### 18.3 检查系统限制

```bash
# 检查文件描述符限制
ulimit -n

# 检查系统级限制
cat /proc/sys/fs/file-max

# 检查内存限制
free -h
```

### 18.4 检查网络内核参数

```bash
# 检查常用网络优化参数
sysctl net.core.default_qdisc
sysctl net.ipv4.tcp_fastopen
sysctl net.ipv4.tcp_slow_start_after_idle
sysctl net.core.rmem_max
sysctl net.core.wmem_max
```

### 18.5 手动启用 BBR

```bash
# 临时启用
sysctl -w net.core.default_qdisc=fq
sysctl -w net.ipv4.tcp_congestion_control=bbr

# 持久化
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p
```

---

## 19. 备份与恢复

### 19.1 查看配置目录结构

```bash
ls -la /etc/vless-reality/
```

**正常目录结构：**
```
/etc/vless-reality/
├── config.json          # Xray 配置
├── singbox.json         # Sing-box 配置
├── db.json              # 数据库 (协议配置、用户、规则)
├── telegram.json        # TG 通知配置
├── warp.json            # WARP 配置
├── sub.info             # 订阅信息
├── certs/               # 证书目录
│   ├── server.crt
│   └── server.key
├── sub/                 # 订阅文件目录
└── ...
```

### 19.2 备份所有配置

```bash
# 创建备份目录
mkdir -p ~/vless-backup-$(date +%Y%m%d)

# 备份整个配置目录
cp -r /etc/vless-reality/* ~/vless-backup-$(date +%Y%m%d)/

# 或创建压缩包
tar -czvf ~/vless-backup-$(date +%Y%m%d).tar.gz /etc/vless-reality/
```

### 19.3 备份关键文件

```bash
# 只备份关键配置
cp /etc/vless-reality/db.json ~/db-backup.json
cp /etc/vless-reality/config.json ~/config-backup.json
cp -r /etc/vless-reality/certs ~/certs-backup/
```

### 19.4 恢复配置

```bash
# 恢复整个目录
cp -r ~/vless-backup-20240101/* /etc/vless-reality/

# 或从压缩包恢复
tar -xzvf ~/vless-backup-20240101.tar.gz -C /

# 重新生成配置并重启服务
/root/vless-server.sh --regen
systemctl restart vless-reality vless-singbox
```

### 19.5 验证恢复结果

```bash
# 检查配置文件语法
/usr/local/bin/xray run -test -c /etc/vless-reality/config.json

# 检查数据库完整性
cat /etc/vless-reality/db.json | jq '.xray | keys'

# 检查服务状态
systemctl status vless-reality
```

---

## 20. 常见问题

### Q1: 服务启动失败

**排查步骤：**
```bash
# 1. 查看详细错误
journalctl -u vless-reality -n 50

# 2. 测试配置文件
/usr/local/bin/xray run -test -c /etc/vless-reality/config.json

# 3. 检查端口冲突
ss -tlnp | grep :443
```

### Q2: 客户端连接失败

**排查步骤：**
```bash
# 1. 检查服务运行
systemctl status vless-reality

# 2. 检查端口监听
ss -tlnp | grep :443

# 3. 检查防火墙
iptables -L -n | grep 443

# 4. 测试本地连接
curl -v --connect-timeout 5 https://localhost:443 2>&1 | head -20
```

### Q3: 证书申请失败

**排查步骤：**
```bash
# 1. 检查 80 端口
ss -tlnp | grep :80

# 2. 检查域名解析
dig your-domain.com +short

# 3. 手动申请测试
~/.acme.sh/acme.sh --issue -d your-domain.com --standalone --debug
```

### Q4: 端口跳跃不生效

**排查步骤：**
```bash
# 1. 检查 iptables 规则
iptables -t nat -L PREROUTING -n -v

# 2. 检查数据库配置
cat /etc/vless-reality/db.json | jq '.singbox.hy2 | {hop_enable, hop_start, hop_end}'

# 3. 重新应用规则
iptables -t nat -A PREROUTING -p udp --dport 20000:50000 -j REDIRECT --to-ports 8443

# 4. 测试 UDP 端口
nc -u -v your-server-ip 30000
```

### Q5: 订阅无法访问

**排查步骤：**
```bash
# 1. 检查 Nginx 状态
systemctl status nginx

# 2. 检查 Nginx 配置
nginx -t

# 3. 检查订阅文件
ls -la /etc/vless-reality/sub/

# 4. 测试本地访问
curl -k https://localhost:8443/sub/your_token
```

### Q6: Telegram 通知不发送

**排查步骤：**
```bash
# 1. 检查配置
cat /etc/vless-reality/telegram.json | jq .

# 2. 测试 API 连接
curl -s "https://api.telegram.org/bot$(cat /etc/vless-reality/telegram.json | jq -r '.bot_token')/getMe"

# 3. 手动触发
/root/vless-server.sh --sync-traffic
```

### Q7: WARP 分流不生效

**排查步骤：**
```bash
# 1. 检查 WARP 模式
cat /etc/vless-reality/db.json | jq '.routing.warp_mode'

# 2. 检查 WARP 配置
cat /etc/vless-reality/warp.json | jq .

# 3. 检查 Xray 出站
cat /etc/vless-reality/config.json | jq '.outbounds[] | select(.tag | startswith("warp"))'

# 4. 检查路由规则
cat /etc/vless-reality/config.json | jq '.routing.rules[] | select(.outboundTag | startswith("warp"))'

# 5. 官方客户端模式检查 SOCKS5
ss -tlnp | grep 40000
warp-cli status
```

### Q8: 回落协议连接失败

**排查步骤：**
```bash
# 1. 检查主协议是否运行
cat /etc/vless-reality/config.json | jq '.inbounds[0]'

# 2. 检查回落配置
cat /etc/vless-reality/config.json | jq '.inbounds[0].settings.fallbacks'

# 3. 检查子协议监听
ss -tlnp | grep -E "8080|8081"  # 回落内部端口

# 4. 检查 path 是否匹配
cat /etc/vless-reality/db.json | jq '.xray["vless-ws"].path, .xray["vmess-ws"].path, .xray["trojan-ws"].path'
```

---

## 快速诊断脚本

将以下内容保存为 `diagnose.sh` 并运行：

```bash
#!/bin/bash
CFG="/etc/vless-reality"

echo "=== VLESS-Server 完整诊断 ==="
echo ""

# 服务状态
echo "[1] 服务状态"
for svc in vless-reality vless-singbox vless-snell vless-snell-v5 vless-anytls nginx; do
    if systemctl is-active --quiet $svc 2>/dev/null; then
        echo "  ✓ $svc: 运行中"
    elif systemctl list-unit-files | grep -q "^$svc"; then
        echo "  ✗ $svc: 已安装但未运行"
    fi
done
echo ""

# 进程检查
echo "[2] 进程检查"
for proc in xray sing-box snell-server shadow-tls anytls-server caddy nginx warp-cli; do
    if pgrep -f "$proc" >/dev/null 2>&1; then
        echo "  ✓ $proc: 存在"
    fi
done
echo ""

# 端口检查
echo "[3] 监听端口"
ss -tlnp 2>/dev/null | awk 'NR>1 {print "  " $4 " (" $6 ")"}' | head -15
echo ""

# 证书检查
echo "[4] 证书状态"
if [[ -f $CFG/certs/server.crt ]]; then
    if openssl x509 -in $CFG/certs/server.crt -noout -checkend 2592000 2>/dev/null; then
        echo "  ✓ 证书有效"
        echo "  域名: $(cat $CFG/cert_domain 2>/dev/null)"
    else
        echo "  ✗ 证书即将过期或已过期"
    fi
else
    echo "  - 无证书"
fi
echo ""

# 配置检查
echo "[5] 配置文件"
if /usr/local/bin/xray run -test -c $CFG/config.json 2>&1 | grep -q "Configuration OK"; then
    echo "  ✓ Xray 配置正确"
else
    echo "  ✗ Xray 配置错误"
fi
if [[ -f $CFG/singbox.json ]] && /usr/local/bin/sing-box check -c $CFG/singbox.json 2>&1 | grep -q ""; then
    echo "  ✓ Sing-box 配置正确"
fi
echo ""

# WARP 检查
echo "[6] WARP 状态"
warp_mode=$(cat $CFG/db.json 2>/dev/null | jq -r '.routing.warp_mode // "未配置"')
echo "  模式: $warp_mode"
if [[ "$warp_mode" == "official" ]]; then
    if which warp-cli >/dev/null 2>&1; then
        echo "  状态: $(warp-cli status 2>/dev/null | grep -i status || echo '未知')"
    fi
elif [[ "$warp_mode" == "wgcf" ]]; then
    if [[ -f $CFG/warp.json ]]; then
        echo "  ✓ WGCF 配置存在"
    fi
fi
echo ""

# 定时任务
echo "[7] 定时任务"
cron_sync=$(crontab -l 2>/dev/null | grep sync-traffic)
cron_acme=$(crontab -l 2>/dev/null | grep acme)
[[ -n "$cron_sync" ]] && echo "  ✓ 流量同步: 已配置" || echo "  - 流量同步: 未配置"
[[ -n "$cron_acme" ]] && echo "  ✓ 证书续期: 已配置" || echo "  - 证书续期: 未配置"
echo ""

# 协议统计
echo "[8] 已安装协议"
echo "  Xray: $(cat $CFG/db.json 2>/dev/null | jq -r '.xray | keys | join(", ")' || echo '无')"
echo "  Sing-box: $(cat $CFG/db.json 2>/dev/null | jq -r '.singbox | keys | join(", ")' || echo '无')"
echo "  独立: $(cat $CFG/db.json 2>/dev/null | jq -r '.standalone | keys | join(", ")' || echo '无')"
echo ""

echo "=== 诊断完成 ==="
```

---

*最后更新: 2026*

