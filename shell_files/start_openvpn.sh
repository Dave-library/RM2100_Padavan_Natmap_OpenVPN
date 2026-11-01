#!/bin/sh
# 这行是 shebang，指定使用 /bin/sh 作为解释器执行本脚本

# =============================================================================
# 脚本名称: start_openvpn.sh
# 用途: 启动 router 上 OpenVPN 服务的 natmap 进程和 monitor_openvpn.sh
#       启动前先 ping 内网 IP，不可达则退出并微信通知
#       保活由 check_ip_change.sh 负责，本脚本仅用于首次启动或手动调用
# 目录: /etc/storage/bin/natmap/openvpn/
# 依赖: pgrep, ping, logger, date
# =============================================================================

# 空行

# ----------------------------------------
# 步骤1：定义日志路径
# ----------------------------------------

# 定义 BASE_DIR 变量，值为 natmap 根目录
BASE_DIR="/etc/storage/bin/natmap"

# 定义 OPENVPN_DIR 变量，值为 router 的 openvpn 服务目录
OPENVPN_DIR="$BASE_DIR/openvpn"

# 定义 OPENVPN_LOGS 变量，值为 router 的 openvpn 日志目录
OPENVPN_LOGS="$OPENVPN_DIR/logs"

# 创建日志目录（如果不存在），-p 忽略已存在
# 2>/dev/null 丢弃错误输出
mkdir -p "$OPENVPN_LOGS" 2>/dev/null

# 定义 MAIN_LOG 变量，值为主控日志文件路径
MAIN_LOG="$OPENVPN_LOGS/openvpn_ip_monitor.log"

# 空行

# ----------------------------------------
# 步骤2：检查目标 IP 可达性
# ----------------------------------------

# ping router 本机 IP 172.16.10.1
# -c 1 发送 1 个 ICMP 包
# -W 2 超时 2 秒
# > /dev/null 2>&1 丢弃所有输出
ping -c 1 -W 2 172.16.10.1 > /dev/null 2>&1

# 检查退出码，0 表示成功（可达），非 0 表示失败（不可达）
if [ $? -ne 0 ]; then
    # ---- 不可达：退出并通知 ----

    # 输出提示到终端
    echo "目标 IP 172.16.10.1 不可达，跳过启动 router的openvpn natmap"

    # 记录到日志文件（日志中服务名使用 router的openvpn）
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [start_openvpn] 目标 IP 172.16.10.1 不可达，跳过启动 router的openvpn natmap" >> "$MAIN_LOG"

    # 发送微信通知（微信推送标题保持 [OPENVPN] 不变）
    /etc/storage/script/Sh45_wx_send.sh send_message "[OPENVPN]内网服务不可达" "IP 172.16.10.1 无法 ping 通，跳过端口映射。"

    # 以非 0 状态退出
    exit 1
fi

# 空行

# ----------------------------------------
# 步骤3：启动 natmap 进程
# ----------------------------------------

# 检查 natmap 进程是否已经运行
# pgrep -f 搜索完整命令行，匹配模式 "natmap.*172.16.10.1.*61194"
# ! 取反，表示"如果不存在"
if ! pgrep -f "natmap.*172.16.10.1.*61194" > /dev/null; then
    # 进程不存在，启动它

    # 输出启动信息到终端
    echo "启动 natmap (router的openvpn)..."

    # 记录到日志文件（日志中服务名使用 router的openvpn）
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [start_openvpn] 启动 natmap (router的openvpn)" >> "$MAIN_LOG"

    # 后台运行 natmap
    # -d 守护进程模式
    # -s turn.cloudflare.com STUN 服务器
    # -h baidu.com 心跳检测域名
    # -b 0 绑定所有接口
    # -t 172.16.10.1 目标内网 IP（router 本机）
    # -p 61194 router 上 OpenVPN 服务监听的端口
    # 2>&1 将错误输出重定向到标准输出
    # while read line 逐行读取输出并添加时间戳
    # >> "$OPENVPN_LOGS/openvpn_natmap.log" 追加到日志文件
    # & 放在后台运行
    /etc/storage/bin/natmap/natmap -d -s turn.cloudflare.com -h baidu.com -b 0 -t 172.16.10.1 -p 61194 2>&1 | while read line; do
        echo "$(date '+%Y-%m-%d %H:%M:%S') $line"
    done >> "$OPENVPN_LOGS/openvpn_natmap.log" &
fi

# 空行

# ----------------------------------------
# 步骤4：等待日志文件生成
# ----------------------------------------

# sleep 5 秒确保 natmap 有足够时间创建日志文件和初始化
sleep 5

# 空行

# ----------------------------------------
# 步骤5：启动 monitor_openvpn.sh
# ----------------------------------------

# 检查 monitor_openvpn.sh 是否已经运行
if ! pgrep -f "monitor_openvpn.sh" > /dev/null; then
    # 未运行，启动它

    # 输出启动信息到终端
    echo "启动 monitor_openvpn.sh..."

    # 记录到日志文件
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [start_openvpn] 启动 monitor_openvpn.sh" >> "$MAIN_LOG"

    # 后台运行 monitor_openvpn.sh
    # > "$OPENVPN_LOGS/openvpn_debug.log" 2>&1 将所有输出重定向到 debug 日志
    /etc/storage/bin/natmap/openvpn/monitor_openvpn.sh > "$OPENVPN_LOGS/openvpn_debug.log" 2>&1 &
fi

# 脚本正常结束