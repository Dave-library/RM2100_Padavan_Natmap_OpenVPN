============================================================================
        natmap 端口映射与自动维护系统（OpenVPN 专用版）- 完整教程
============================================================================

一、系统概述

本系统专为小米/红米路由器（Padavan/老毛子固件）设计，通过 natmap 实现
NAT 穿透（打洞），将路由器上 OpenVPN 服务端的 TCP 61194 端口映射到公网，
并自动维护整个流程的稳定性。

本版本只保留 OpenVPN 一个服务，不包含 ROUTER 5001、NAS 等其他服务。

核心功能：
  1. 实时监控 WAN IP 变化，每30秒检测，变化时自动重启 natmap。
  2. 进程保活：natmap 和监控脚本崩溃后自动恢复（6小时冷却防频繁重试）。
  3. 防火墙自动管理：端口变化时增删 INPUT 规则，规则被误删后15秒内补回。
  4. 微信推送：更新成功/失败、IP变化原因、服务不可达等实时通知。
  5. 日志轮转：每天4:00~6:00清理超7天或超1MB的日志文件。

服务地址与端口：
  OpenVPN 服务端：172.16.10.1:61194（路由器自身，TCP over IPv4）
  natmap 映射目标：172.16.10.1:61194

日志文本约定：
  所有系统日志、主控日志、debug 日志中的服务名统一写作 “router的openvpn”。

微信推送约定：
  推送标题保持 [OPENVPN] 不变，内容格式与其他服务一致。


二、快速部署（五步走）

1. 上传脚本至路由器 /etc/storage/bin/natmap/openvpn/，并赋予可执行权限：
   chmod +x /etc/storage/bin/natmap/check_ip_change.sh
   chmod +x /etc/storage/bin/natmap/openvpn/*.sh
   chmod +x /etc/storage/bin/natmap/natmap

2. 配置微信推送脚本 /etc/storage/script/Sh45_wx_send.sh（需提前设置好 Webhook）。

3. 在路由器 Web 管理后台（高级设置 -> 参数设置 -> 脚本）的“在路由器启动后执行”中添加：
   /etc/storage/bin/natmap/check_ip_change.sh &

4. 在“在路由器关闭之前执行”中添加：
   /etc/storage/bin/natmap/openvpn/stop_openvpn.sh

5. 手动启动测试（可选）：
   /etc/storage/bin/natmap/check_ip_change.sh &
   查看日志：tail -f /etc/storage/bin/natmap/openvpn/logs/openvpn_ip_monitor.log

保存配置：
  Web 页面“系统管理 - 恢复/导出/上传设置”中：
   - “保存 NVRAM 到闪存” -> 提交
   - “保存 /etc/storage/ 内容到闪存” -> 提交
  或 SSH 中执行：
   mtd_storage.sh save
   nvram commit


三、目录结构

/etc/storage/bin/natmap/
├── check_ip_change.sh              主监控脚本（常驻后台）
├── natmap                          natmap 二进制程序
└── openvpn/                        OpenVPN 服务目录
    ├── monitor_openvpn.sh          端口监控（解析日志、管理防火墙、推送）
    ├── start_openvpn.sh            启动脚本（检查内网可达后拉起服务）
    ├── stop_openvpn.sh             停止脚本（删除规则、终止进程）
    └── logs/                       日志目录
        ├── openvpn_ip_monitor.log  主控日志（IP变化、保活、日志轮转）
        ├── openvpn_natmap.log      natmap 输出日志（公网IP+端口）
        └── openvpn_debug.log       monitor 调试日志（防火墙、推送）

说明：
  - 没有 router/ 和 nas/ 目录。
  - 没有 router_ip_monitor.log、nas_ip_monitor.log 等文件。
  - 所有日志集中在 openvpn/logs/ 下。


四、各脚本详细说明

4.1 check_ip_change.sh（主监控脚本）
  功能：
   - 每30秒获取一次稳定的 WAN IP。
   - IP变化时重启 OpenVPN 的 natmap。
   - 保活检测：若 natmap 或 monitor_openvpn.sh 进程缺失，自动拉起。
   - 每日4:00~6:00执行日志轮转（超7天或超1MB清空）。
   - 内网IP不可达时发送微信告警，进入6小时冷却。
   - 将IP变化原因写入 /tmp/ip_change_reason_openvpn。
  日志文本：
   - [ensure_openvpn] router的openvpn 被调用
   - [ensure_openvpn] router的openvpn 进程存在
   - [ensure_openvpn] router的openvpn 冷却中，跳过检测
   - router的openvpn IP 可达，启动 router的openvpn natmap 和 monitor
   - router的openvpn IP 不可达，下次检测: ...
   - IP变化，重启 router的openvpn natmap (172.16.10.1:61194)
   - 停止旧 router的openvpn natmap 进程 PID=...
   - 已启动新 router的openvpn natmap (172.16.10.1:61194)
  启动方式： nohup /etc/storage/bin/natmap/check_ip_change.sh > /dev/null 2>&1 &

4.2 monitor_openvpn.sh（端口监控脚本）
  功能：
   - 监控 openvpn_natmap.log，提取最新公网IP和端口。
   - 检测到端口变化时，等待20秒确认稳定。
   - 更新防火墙规则（删除旧端口，添加新端口）。
   - 将当前端口写入 /tmp/natmap_openvpn_port。
   - 发送微信推送，标题固定为 [OPENVPN]。
   - 每15秒巡检防火墙规则，缺失时自动补充。
  日志文本：
   - 检测到 router的openvpn 公网地址和端口变化: ...
   - 检测到 router的openvpn 出口地址和端口变化: ...
   - router的openvpn 端口不稳定或 IP 变化，放弃本次更新
   - 防火墙 INPUT 规则已添加: router的openvpn 出口地址端口: -> ...
   - 防火墙 INPUT 规则缺失，已自动补充: router的openvpn 出口地址端口: -> ...
   - 已发送微信推送: router的openvpn 公网地址和端口: -> ...
   - 已发送微信推送: router的openvpn 出口地址和端口: -> ...
  锁文件：/tmp/monitor_openvpn.lock（防重复运行）

4.3 start_openvpn.sh（启动脚本）
  功能：
   - ping 目标内网IP 172.16.10.1，不可达则退出并微信告警。
   - 启动 natmap（若未运行）。
   - 启动 monitor_openvpn.sh（若未运行）。
  日志文本：
   - [start_openvpn] 目标 IP 172.16.10.1 不可达，跳过启动 router的openvpn natmap
   - [start_openvpn] 启动 natmap (router的openvpn)
   - [start_openvpn] 启动 monitor_openvpn.sh
  注意：日常保活由 check_ip_change.sh 负责，本脚本仅用于首次启动或手动调试。
  开机时不要执行，否则拨号未完成会误报警告。

4.4 stop_openvpn.sh（停止脚本）
  功能：
   - 从 /tmp/natmap_openvpn_port 读取当前端口并删除规则。
   - 从 openvpn_natmap.log 提取所有历史端口并删除（确保无残留）。
   - 停止 natmap 和 monitor_openvpn.sh 进程。
   - 删除锁文件。
  日志文本：
   - [stop_openvpn] 已删除 router的openvpn INPUT 规则（端口 ...）
   - [stop_openvpn] 已停止 router的openvpn natmap (PID: ...)
   - [stop_openvpn] 已停止 monitor_openvpn.sh (PID: ...)
   - [stop_openvpn] router的openvpn 的 natmap 相关进程处理完成，添加的防火墙规则已删除

4.5 natmap（核心二进制）
  命令行参数：
    natmap -d -s turn.cloudflare.com -h baidu.com -b 0 -t 172.16.10.1 -p 61194
  参数说明：
    -d                      守护进程模式
    -s turn.cloudflare.com  STUN 服务器（可换成 stun.qq.com 等）
    -h baidu.com            心跳检测域名
    -b 0                    绑定所有接口
    -t 172.16.10.1          目标内网IP（路由器自身）
    -p 61194                目标端口（OpenVPN TCP 监听端口）
  输出格式示例：
    2026-10-30 22:41:02 112.114.45.178 35286 2001::89d6:7072:2db2 42566 tcp 100.64.233.20
    列含义：日期 时间 公网IP 公网端口 内网IP 本地端口 协议 目标IP

  客户端连接方式：
    使用微信推送中的“公网地址: 公网IP:公网端口”，不是固定的 61194。
    例如：112.114.45.178:35286


五、微信推送原因说明

IP变化触发（check_ip_change.sh）：
  定时重启（凌晨3:00）        -> 推送原因：“定时重启（凌晨 3:00）”
  手动重启（SSH/Web触发）     -> “手动重启（SSH/Web 触发）”
  PPPoE断线重连              -> “网络断线重连（PPPoE 链路中断）”
  凌晨2:00~5:00重拨          -> “运营商例行维护（凌晨时段重拨）”
  其他情况                    -> “外网链路变化，重新拨号”

端口变化触发（monitor_openvpn.sh）：
  若120秒内有IP变化原因，则复用该原因；否则使用“端口映射重新分配”。

内网不可达告警（start/check脚本）：
  [OPENVPN]内网服务不可达
  [OPENVPN] 端口更新失败 (第N条)

推送成功标题：
  [OPENVPN] 端口更新成功 (第N条)

推送内容示例：
  公网地址: 112.114.45.178:35286
  出口地址: 100.64.233.20:42566
  本地地址: 172.16.10.1:61194
  变化原因: 外网链路变化，重新拨号

推送防重复：同一端口60秒内不重复推送。


六、Web 管理页面配置（关键点）

在“在路由器启动后执行”中只添加一条：
  /etc/storage/bin/natmap/check_ip_change.sh &
  不要添加 start_openvpn.sh，原因：
  - 开机时PPPoE拨号尚未完成，start脚本会误判内网不可达并发送错误告警。
  - 主脚本启动后30秒内拨号完成，自动拉起服务，流程正常。

在“在路由器关闭之前执行”中添加：
  /etc/storage/bin/natmap/openvpn/stop_openvpn.sh

保存配置：
  系统管理 - 恢复/导出/上传设置：
   - “保存 NVRAM 到闪存” -> 提交
   - “保存 /etc/storage/ 内容到闪存” -> 提交
  或 SSH：
   mtd_storage.sh save
   nvram commit


七、手动操作命令速查

启动服务：
  /etc/storage/bin/natmap/check_ip_change.sh &

停止所有服务：
  /etc/storage/bin/natmap/openvpn/stop_openvpn.sh
  ps | grep check_ip_change.sh | grep -v grep | awk '{print $1}' | xargs kill

重启主监控（子进程自动接管）：
  pkill -f check_ip_change.sh
  sleep 2
  /etc/storage/bin/natmap/check_ip_change.sh &

查看进程状态：
  ps | grep -E "natmap|monitor_openvpn|check_ip" | grep -v grep

查看防火墙规则：
  iptables -L INPUT -n | grep ACCEPT

查看当前放行端口：
  cat /tmp/natmap_openvpn_port

手动删除一条规则（测试自动修复）：
  iptables -D INPUT -p tcp --dport <端口号> -j ACCEPT
  等待15~30秒后观察日志，应自动恢复。

查看主控日志：
  tail -f /etc/storage/bin/natmap/openvpn/logs/openvpn_ip_monitor.log

查看 natmap 日志：
  tail -f /etc/storage/bin/natmap/openvpn/logs/openvpn_natmap.log

查看调试日志（推送排查）：
  tail -f /etc/storage/bin/natmap/openvpn/logs/openvpn_debug.log

查看系统日志（monitor 推送记录）：
  logread | grep monitor_openvpn | tail -20

查看系统日志（check_ip 保活记录）：
  logread | grep check_ip | tail -20


八、日志文件与轮转策略

日志文件：
  openvpn_ip_monitor.log   -> 主控日志（IP变化、保活、日志轮转）
  openvpn_natmap.log       -> natmap 输出（公网IP+端口）
  openvpn_debug.log        -> monitor 调试日志（防火墙、推送）

轮转策略：
  - 触发时间：每日凌晨4:00~6:00（2小时窗口，避免错过）
  - 触发条件：文件修改时间超过7天 或 文件大小超过1MB
  - 处理方式：清空文件内容（不删除文件）
  - 标志文件：/tmp/natmap_log_rotate_done_YYYYMMDD（同一天只执行一次）
  - 轮转对象：openvpn_ip_monitor.log、openvpn_natmap.log
  - 轮转记录：写入 openvpn_ip_monitor.log，并记录到系统日志

注意：
  openvpn_debug.log 不参与自动轮转，因为它只保存微信返回的 JSON，
  通常很小；如需清理，手动执行 > openvpn_debug.log 即可。


九、STUN 服务器建议

国内推荐：stun.qq.com 或 stun.l.google.com:19302（延迟低）
国际通用：turn.cloudflare.com（全球可达）
若自建 VPS 可部署 coturn，指定 -s your-vps-ip

修改位置：
  check_ip_change.sh 中 ensure_openvpn() 和 restart_natmap() 里的 natmap 启动命令
  start_openvpn.sh 中的 natmap 启动命令
  三处都要改，保持一致。


十、防火墙规则优化说明

规则添加：iptables -A INPUT -p tcp --dport <端口> -j ACCEPT
规则删除：iptables -D INPUT -p tcp --dport <端口> -j ACCEPT
规则检查：iptables -C INPUT -p tcp --dport <端口> -j ACCEPT
端口记录文件：/tmp/natmap_openvpn_port
巡检周期：每15秒检查一次，缺失则立即补充。
协议：TCP（与 OpenVPN 服务端 TCP over IPv4 一致）


十一、技术细节

进程管理：
  - 主脚本 while true 循环常驻后台。
  - 子进程 natmap 和 monitor_openvpn.sh 由主脚本管理。
  - 主脚本被杀后，子进程变为孤儿，新主脚本启动后通过 pgrep 检测并接管。

冷却机制：
  - 不可达后进入6小时冷却（21600秒），期间不再检测。
  - 进程存在时自动清除冷却。

锁机制：
  - 使用 flock 文件锁防止 monitor_openvpn.sh 重复运行。
  - 锁文件：/tmp/monitor_openvpn.lock。
  - 脚本退出时文件描述符自动关闭，锁自动释放。

端口记录：
  - /tmp/natmap_openvpn_port 保存当前防火墙放行的本地端口。
  - 重启后 /tmp 清空，但 openvpn_natmap.log 有完整历史，monitor 会重新解析。

原因文件：
  - /tmp/ip_change_reason_openvpn 由 check_ip_change.sh 写入。
  - monitor_openvpn.sh 只在文件 120 秒内写入时才使用该原因。
  - 超过 120 秒则使用默认原因“端口映射重新分配”。


十二、故障排查

微信没有推送：
  - 检查推送脚本是否存在且可执行：ls -la /etc/storage/script/Sh45_wx_send.sh
  - 查看 monitor 调试日志：tail -50 .../openvpn_debug.log
  - 查看系统日志：logread | grep monitor_openvpn | tail -20

服务无法启动：
  - 查看主控日志：tail -50 .../openvpn_ip_monitor.log
  - 检查进程：ps | grep -E "natmap|monitor_openvpn|check_ip" | grep -v grep
  - 手动 ping 内网IP：ping -c 3 172.16.10.1
  - 确认 OpenVPN 服务端监听 61194：netstat -lntp | grep 61194

防火墙规则被删后没有自动补充：
  - 检查端口文件是否存在：ls -la /tmp/natmap_openvpn_port
  - 检查 monitor 进程是否运行：ps | grep monitor_openvpn
  - 查看系统日志中是否有补充记录：logread | grep "防火墙 INPUT 规则缺失" | tail -5

客户端无法连接 OpenVPN：
  - 确认微信推送里的“公网地址: 公网IP:公网端口”是最新的；
  - 确认路由器本机 172.16.10.1:61194 可访问：netstat -lntp | grep 61194
  - 确认 iptables 有 natmap 本地端口的 ACCEPT 规则：iptables -L INPUT -n | grep ACCEPT
  - 确认 natmap 日志有公网 IP 和公网端口输出：tail -20 .../openvpn_natmap.log

日志没有轮转：
  - 确认 check_ip_change.sh 正在运行：ps | grep check_ip
  - 确认当前时间在 4:00~6:00 之间：date +%H
  - 确认标志文件是否已存在：ls -la /tmp/natmap_log_rotate_done_*


十三、扩展与自定义

更换推送方式：
  修改所有脚本中调用 /etc/storage/script/Sh45_wx_send.sh 的部分，
  替换为其他推送脚本（飞书、钉钉等），保持参数格式一致。

调整检测间隔：
  修改 check_ip_change.sh 主循环中的 sleep 30（当前30秒）
  修改 monitor_openvpn.sh 主循环中的 sleep 15（当前15秒）

修改端口：
  如果 OpenVPN 服务端端口不是 61194，需要同时修改：
   - check_ip_change.sh 中 ensure_openvpn() 和 restart_natmap() 的 -p 参数
   - start_openvpn.sh 中的 -p 参数
   - pgrep 匹配模式 "natmap.*172.16.10.1.*61194"
   - monitor_openvpn.sh 中本地地址文本 "172.16.10.1:61194"
   - stop_openvpn.sh 中 pgrep 匹配模式

修改目标 IP：
  OpenVPN 服务端在路由器自身，目标 IP 固定为 172.16.10.1。
  如果 OpenVPN 服务端在 NAS，需要把 172.16.10.1 全部替换为 NAS 的 IP，
  并确认该 IP 固定可达。


十四、注意事项

  1. 所有脚本必须具有可执行权限（chmod +x）。
  2. 修改脚本后必须执行 mtd_storage.sh save 或 Web 页面“保存 /etc/storage/ 内容到闪存”。
  3. 防火墙规则保存在内存，重启后丢失，由 monitor 脚本重新添加。
  4. 日志轮转策略可防止存储撑爆，轮转窗口为 4:00~6:00。
  5. 端口记录文件在 /tmp，重启后丢失，但 natmap 日志有完整历史。
  6. 确保内网 IP 172.16.10.1 固定且可达（OpenVPN 在路由器自身时天然满足）。
  7. 微信推送脚本需提前配置好 Webhook 或 API。
  8. 开机启动只加 check_ip_change.sh 一条命令，不要加 start_openvpn.sh。
  9. 若需要更改 STUN 服务器，请同时修改 check_ip_change.sh 和 start_openvpn.sh 中的 -s 参数。
 10. OpenVPN 服务端 Web 端配置为 TCP over IPv4、端口 61194，iptables 规则也使用 tcp，
     不要改成 udp，否则防火墙规则和服务端协议不一致。
 11. 客户端连接使用微信推送的“公网地址: 公网IP:公网端口”，不是固定的 61194。


十五、版本信息

  脚本名称：natmap 端口映射与自动维护系统（OpenVPN 专用版）
  版本：v1.0
  最后更新：2026-10-30
  适用平台：Padavan/老毛子固件（小米/红米路由器）
  服务地址：172.16.10.1:61194（TCP over IPv4）
  日志服务名：router的openvpn
  微信标题：[OPENVPN]
  依赖工具：natmap, iptables, pgrep, flock, logger, date, awk, grep,
           sed, cut, tr, xargs, ping, kill, ps, sleep, tee, nohup


============================================================================
  祝使用顺利！
============================================================================