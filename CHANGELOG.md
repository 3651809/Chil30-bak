# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.4.9] - 2026-02-12

**Fixed**

- 修复 VLESS-XHTTP TLS+CDN 模式安装时闪退的问题
- 修复 crontab 命令缺失导致流量统计和过期检查失败的问题

## [3.4.9] - 2026-02-08

### Added
- 新增用户到期日期功能
  - 添加用户时可设置到期时间（天数或日期格式）
  - 用户列表显示剩余天数（颜色区分：红色=已过期/今天，黄色=3天内）
  - 用户管理菜单新增「设置到期日期 (e)」选项
  - 过期用户自动禁用（保留配置，方便续期）
  - 支持手动执行 `--check-expire` 或安装 cron 自动检查
  - 过期前3天 + 过期当天 TG 通知提醒
- 新增 Clash/Clash Meta 配置输出
  - VLESS-WS、VMess-WS、Hysteria2、Trojan 协议支持 Clash YAML 格式
- 新增 qrencode 自动安装，移除在线二维码 API 回退功能

### Fixed
- 修复证书申请失败时自动回退到自签名证书的问题
  - 现在会提供选项：重试/DNS模式/自签名/取消
- 修复 VLESS-WS 协议显示名称（改为 VLESS-WS-TLS）
- 修复 CF Tunnel 在 Alpine/IPv6 环境下崩溃的问题（正则兼容性）
- 修复 SOCKS5 协议安装时重复询问用户名密码的问题
- 修复 Snell+ShadowTLS 协议无 IPv6 出口的问题
## [3.4.8] - 2026-02-06

### Added
- 新增 Surge 订阅对 TUIC 和 AnyTLS 协议的支持
- 新增完全卸载时的配置目录删除提示
  - 显示配置文件所在目录 `/etc/vless-reality/`
  - 提供完全删除命令 `rm -rf /etc/vless-reality/`
- 新增自定义密码功能
  - 适用于 SOCKS5、SS2022、Hysteria2、Trojan、Snell、TUIC、AnyTLS、NaïveProxy 等协议
  - 添加用户时也支持自定义密码

### Fixed
- 修复停止订阅服务时 Nginx 未正确停止的问题
  - 检查是否还有其他 Nginx 配置文件
  - 如果没有其他配置，直接停止 Nginx 服务
  - 如果有其他配置，仅重载 Nginx
- 修复添加用户时用户名大小写冲突导致 Xray 启动失败的问题

## [3.4.7] - 2026-02-05

### Added
- 新增 Sing-box 协议多用户支持
  - Hysteria2/TUIC 协议支持添加多个用户
  - 每个用户可配置独立路由（直连/WARP）
  - 使用 `auth_user` 路由规则实现用户级分流
  - 添加/删除用户后自动重建配置并重载服务
  - 注：流量统计功能需要完整版 sing-box（官方精简版不支持 v2ray_api）

### Fixed
- 修复 Sing-box 升级后 Hysteria2 不可用的问题
- 修复 Reality 安装时自签证书被误识别为真实证书的问题
- 修复 TG 每日推送无法触发的问题

### Changed
- 增强每日流量报告内容
  - 用户详情显示协议名称
  - 添加已安装协议列表汇总
- 每日推送时间支持设置到分钟
  - 支持 HH:MM 格式（如 9:30）或 HH 格式（如 9）
  - 已启用时可单独修改发送时间

## [3.4.6] - 2026-02-02

### Added
- 新增独立协议检测功能
- 新增 default 用户删除保护
### Fixed
- 修复独立协议在「查看协议配置」菜单中不显示的问题
- 修复用户路由优先级问题
  - 路由规则顺序：API 规则 → 用户规则 → 全局规则
- 修复 Snell 协议错误输出 Loon 配置的问题
- 修复「协议服务管理」菜单独立协议不显示的问题
- 修复端口占用检测误判问题
- 修复完全卸载后 Nginx 未停止的问题
### Changed
- 更新 Reality SNI 列表（精选 22 个大陆三网延迟 <100ms 的苹果子域名）
- 调整 WS 类协议回落触发条件
  - 仅当主协议 (VLESS-Vision/Trojan) 端口为 8443 时才启用回落
- 订阅服务默认端口从 8443 调整为 18443
- 自签名证书 SNI 配置优化



## [3.4.5] - 2026-02-01

### Added
- 新增 Trojan-WS 协议支持
  - Trojan 安装时可选择 TCP 或 WebSocket 传输模式
  - Trojan-WS 支持作为回落子协议（复用 443 端口）
- 新增 FAQ.md 故障排查文档
  - 完整诊断脚本和常见问题解答

### Fixed
- 修复 AnyTLS 协议服务无法启动的问题
- 修复 TG 每日推送无法触发的问题

## [3.4.4] - 2026-01-31

### Fixed
- 修复多IP入出站路由配置不生效的问题
- 修复 Cloudflare Tunnel 命名隧道功能
  - 修复 cloudflared 在纯 IPv6 环境下连接失败的问题
- 改进流量统计功能兼容性
  - sing-box 核心显示暂不支持流量统计的友好提示
  - 独立协议 (Hysteria2/NaiveProxy 等) 显示不支持流量统计的说明
  - 避免在非 Xray 核心环境下出现错误

### Changed
- 将「多IP入出站配置」移动到「分流管理」菜单（选项 5）

## [3.4.3] - 2026-01-29

### Fixed

- 订阅服务 NAT 访问问题
- SNI 列表优化
- 证书 CN 匹配问题
- Alpine 流量统计检测问题
- 完全卸载路径提示

## [3.4.2] - 2026-01-28

### Added
- 新增用户级路由配置功能
  - 同端口不同用户可配置不同出站路由（直连/WARP/链式代理/负载均衡）
  - 用户级路由优先于全局分流规则
  - 添加用户时可选择专属路由
  - 用户管理菜单新增「修改用户路由 (r)」选项
  - 用户列表显示路由配置列
- 新增 XHTTP TLS+CDN 模式
  - 安装 VLESS-XHTTP 时可选择 Reality 模式或 TLS+CDN 模式
  - TLS+CDN 模式使用真实证书，支持通过 Cloudflare CDN（小云朵）代理
  - 自动配置 Nginx 反代 XHTTP (gRPC/h2c) 协议
  - 适合 IP 被墙场景，CDN 保护入站连接
- 新增 VLESS-WS 无 TLS 模式（VLESS-WS-CF）
  - 专为 Cloudflare Tunnel 场景设计
  - 服务器端不需要 TLS，由 CF Tunnel 提供加密
  - Cloudflare Tunnel 快速隧道/命名隧道支持检测
  - 隧道状态页面显示分享链接和二维码

### Fixed
- 修复端口输入循环无法退出的问题（添加 0/q 退出选项）
- 修复 alpine 系统无法查询流量统计问题
- 修复 tgbot 循环发送消息问题 
- 修复 Xray 日志目录不存在导致服务启动失败的问题

## [3.4.1] - 2026-01-27

### Added
- 新增多IP入出站配置功能
  - 支持多IP服务器按入站IP路由到指定出站IP
  - 自动检测系统所有公网IPv4/IPv6地址
  - 交互式管理菜单（添加/删除/启用/禁用规则）
  - 自动生成Xray outbound和routing配置
  - 入口位于：分流配置 → 多IP入出站配置

### Changed
- 优化分流管理菜单布局

## [3.4.0] - 2026-01-26

### Added
- 新增多用户管理功能
  - 添加/删除/查看用户
  - 用户流量配额与统计
  - 实时流量监控
  - 用户启用/禁用
  - 用户分享链接查看
  - TG 通知配置
- 新增 Cloudflare Tunnel 内网穿透功能
  - 支持快速隧道（临时域名）和命名隧道（自定义域名）
  - 适用于 NAT 机器或动态 IP 环境
- 新增双层链式代理 (WARP → 落地节点)
  - 隐藏真实 IP + 解锁流媒体
- 新增随机 SNI 伪装功能
  - 自动随机选择主流网站 SNI
- 新增负载均衡组管理
  - 支持 leastPing/random/roundRobin 策略

### Fixed
- 修复 Alpine 系统 Nginx 安装和配置问题

### Changed
- 优化用户添加/删除后自动重载配置
- 改进菜单布局和交互体验

## [3.3.0] - 2026-01-18

### Added
- 新增 SOCKS5 无认证模式支持
- 新增多端口实例功能与首页显示优化

### Fixed
- 修复 SOCKS5 配置显示中的乱码问题
- 修复全新机器安装 SOCKS5 失败的问题
- 修复数据库函数 JSON 格式问题
- 修复 SOCKS5 和 VMess-WS 协议的 Xray 安装调用
- 移除 SOCKS5 配置中的错误 ip 字段

### Changed
- SOCKS5 无认证模式根据双栈支持智能选择默认监听地址

## [3.2.2] - 2026-01-16

### Added
- 新增 SOCKS5 服务器自定义用户名和密码支持
- 新增一键导入 Alice 家宽功能
  - 支持 Alice 节点负载均衡组管理
  - 支持 SOCKS5 负载均衡器使用 leastPing 策略
  - 集成负载均衡配置到导入流程
  - 分流规则选择出口时支持跳过延迟检测
- 新增 sing-box 负载均衡支持

### Fixed
- 修复完全卸载时未清理 Caddy 二进制文件的问题
- 修复 Alice 节点负载均衡器 SOCKS5 协议兼容性问题
- 删除重复的负载均衡函数定义
- 增强 URL 构建变量替换兼容性
- 增强卸载流程,支持清理所有版本的 Caddy (包括 NaïveProxy 自定义编译版本)

### Changed
- 重构节点延迟检测机制并优化批量测速性能
- 优化出口加载性能,减少 jq 调用次数
- 移除危险操作确认机制并优化解析逻辑

## [3.2.1] - 2026-01-15

### Changed
- 更新版本号至 v3.2.1

## [3.2.0] - 2025-XX-XX

### Added
- 完善核心版本管理与缓存
- 新增核心更新管理功能

### Fixed
- 修复 Snell v4 版本配置兼容性问题
- 优化 IPv6 双栈监听策略与系统兼容性
- 添加 ACME 账户邮箱验证功能
- 更新 acme.sh 安装邮箱配置

### Changed
- 优化分流规则菜单布局，按字母倒序排列
- 在分流规则菜单中添加新规则选项
