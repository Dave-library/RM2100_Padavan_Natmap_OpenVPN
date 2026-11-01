#!/bin/sh
# 这行是 shebang，指定使用 /bin/sh 作为解释器执行本脚本

# =============================================================================
# 脚本名称: monitor_openvpn.sh
# 用途: 监控 router 上 OpenVPN 服务 (172.16.10.1:61194) 的 natmap 日志
#       动态管理防火墙 INPUT 规则，端口稳定后发送微信推送
#       自动巡检防火墙规则，缺失时自动补充
#       增加原因文件时效性判断（120秒内有效），避免复用旧原因
# 目录: /etc/storage/bin/natmap/openvpn/
# 依赖: iptables, pgrep, flock, logger, date, awk, grep, sed, stat
# 备注: 日志文本中服务名统一使用 "router的openvpn"；微信推送标题保持 [OPENVPN] 不变
# =============================================================================

# 空行

# ----------------------------------------
# 步骤1：防止重复运行（锁机制）
# ----------------------------------------

# 定义锁文件路径，存储在 /tmp 临时目录
LOCK_FILE="/tmp/monitor_openvpn.lock"

# 打开文件描述符 200，以写入方式指向锁文件
# exec 是 shell 内置命令，用于重定向当前 shell 的文件描述符
# > 以写入方式打开，如果文件不存在则创建
exec 200>"$LOCK_FILE"

# flock 是文件锁工具
# -n 表示非阻塞模式
# 如果无法获取锁，立即失败返回非 0
# 200 是文件描述符编号，指向锁文件
# || exit 1 表示 flock 失败则退出脚本
flock -n 200 || exit 1

# 脚本退出时文件描述符会自动关闭，锁自动释放

# 空行

# ----------------------------------------
# 步骤2：配置参数
# ----------------------------------------

# 定义 LOG 变量，值为 router 上 openvpn 服务的 natmap 日志文件路径
LOG="/etc/storage/bin/natmap/openvpn/logs/openvpn_natmap.log"

# 定义 LAST_PORT 变量，值为空字符串
# 用于记录上次检测到的本地端口，检测端口是否变化
LAST_PORT=""

# 定义 IPTABLES 变量，值为 iptables 命令的完整路径
IPTABLES="/bin/iptables"

# 定义 COUNT_FILE 变量，值为消息计数文件路径
# 用于记录当天推送的消息条数，显示在推送标题中
COUNT_FILE="/etc/storage/natmap_msg_count_openvpn.txt"

# 定义 PORT_FILE 变量，值为当前放行端口记录文件路径
# 存储当前防火墙放行的端口号，供其他脚本读取
PORT_FILE="/tmp/natmap_openvpn_port"

# 空行

# ---------- 防重复推送变量 ----------

# 定义 last_pushed_port 变量，值为空字符串
# 用于存储上次推送的端口号，判断是否重复
last_pushed_port=""

# 定义 last_push_time 变量，值为 0
# 用于存储上次推送的时间戳（秒）
# 配合端口号判断 60 秒内是否重复推送
last_push_time=0

# 空行

# ----------------------------------------
# 步骤3：获取 WAN 口 IP
# ----------------------------------------

# 定义 get_wan_ip 函数，获取路由器的 WAN 口公网 IP
# 函数没有参数，成功返回 IP 字符串，失败返回 "无法获取"
get_wan_ip() {
    # 从 ppp0 接口获取 IP
    # ifconfig ppp0 显示 ppp0 网络接口信息
    # 2>/dev/null 丢弃错误输出
    # grep 'inet addr' 过滤包含 IP 地址的行
    # awk -F: 以冒号为分隔符，取第2字段
    # 第二个 awk '{print $1}' 取第一个单词（纯 IP 地址）
    local ip=$(ifconfig ppp0 2>/dev/null | grep 'inet addr' | awk -F: '{print $2}' | awk '{print $1}')

    # 如果 ip 非空，输出 IP 并返回
    [ -n "$ip" ] && echo "$ip" && return

    # 备用获取方式：通过路由表获取网卡名再取 IP
    ip=$(ip route get 1 2>/dev/null | awk '{print $5; exit}' | xargs -I {} ifconfig {} 2>/dev/null | grep 'inet addr' | awk -F: '{print $2}' | awk '{print $1}')

    # 如果还是空，输出"无法获取"，否则输出 IP
    [ -n "$ip" ] && echo "$ip" || echo "无法获取"
}

# 空行

# ----------------------------------------
# 步骤4：获取当天消息序号
# ----------------------------------------

# 定义 get_msg_number 函数，获取当天已推送消息的序号
# 每天重置为 1，每次调用自动加 1
get_msg_number() {
    # 获取当天日期，格式如 "2026-07-09"
    TODAY=$(date '+%Y-%m-%d')

    # 如果计数文件不存在，创建并写入 "日期|1"
    if [ ! -f "$COUNT_FILE" ]; then
        echo "$TODAY|1" > "$COUNT_FILE"
        echo "1"
        return
    fi

    # 读取保存的日期和计数
    # cut -d'|' -f1 以 | 为分隔符，取第1字段（日期）
    SAVED_DATE=$(cut -d'|' -f1 "$COUNT_FILE")

    # cut -d'|' -f2 以 | 为分隔符，取第2字段（计数）
    SAVED_COUNT=$(cut -d'|' -f2 "$COUNT_FILE")

    # 如果保存的日期不是今天，重置为今天和计数 1
    if [ "$SAVED_DATE" != "$TODAY" ]; then
        echo "$TODAY|1" > "$COUNT_FILE"
        echo "1"
    else
        # 如果是今天，计数加 1
        NEW_COUNT=$((SAVED_COUNT + 1))
        echo "$TODAY|$NEW_COUNT" > "$COUNT_FILE"
        echo "$NEW_COUNT"
    fi
}

# 空行

# ----------------------------------------
# 步骤5：发送微信推送
# ----------------------------------------

# 定义 send_push 函数，发送微信推送通知
# 参数列表：
#   $1 = ip        公网 IP
#   $2 = wan_port  公网端口
#   $3 = local_port 本地端口
#   $4 = wan_ip    出口 WAN IP
# 注意：微信推送标题和内容保持 [OPENVPN] 原样不变；只有系统日志文本使用 "router的openvpn"
send_push() {
    # 将参数赋值给有意义的变量名
    local ip="$1"
    local wan_port="$2"
    local local_port="$3"
    local wan_ip="$4"

    # 获取当天消息序号
    local num=$(get_msg_number)

    # 默认原因为 "端口映射重新分配"
    local reason="端口映射重新分配"
    # 定义原因文件路径，由 check_ip_change.sh 写入
    local REASON_FILE="/tmp/ip_change_reason_openvpn"

    # 如果原因文件存在，判断其时效性
    if [ -f "$REASON_FILE" ]; then
        # stat -c %Y 获取文件的最后修改时间戳（秒）
        file_time=$(stat -c %Y "$REASON_FILE" 2>/dev/null)
        # 获取当前时间戳
        current_time=$(date +%s)
        # 文件在 120 秒内写入，才使用该原因
        if [ -n "$file_time" ] && [ $((current_time - file_time)) -lt 120 ]; then
            reason=$(cat "$REASON_FILE")
        fi
    fi

    # 组装推送标题（微信推送标题保持 [OPENVPN] 不变）
    local title="[OPENVPN] 端口更新成功 (第${num}条)"

    # 组装推送内容（微信推送内容保持不变）
    local content="公网地址: ${ip}:${wan_port}
出口地址: ${wan_ip}:${local_port}
本地地址: 172.16.10.1:61194
变化原因: ${reason}"

    # 获取当前时间戳
    current_time=$(date +%s)

    # 防重复推送检查
    # 条件1：当前端口与上次推送端口相同
    # 条件2：距离上次推送不到 60 秒
    if [ "$local_port" = "$last_pushed_port" ] && [ $((current_time - last_push_time)) -lt 60 ]; then
        # 满足防重复条件，只记录到系统日志（日志中服务名使用 router的openvpn）
        logger -t "monitor_openvpn" "忽略重复推送: router的openvpn 出口地址端口: -> $local_port"
        return
    fi

    # 检查微信推送脚本是否存在且可执行
    if [ -x "/etc/storage/script/Sh45_wx_send.sh" ]; then
        # 调用微信推送脚本（推送内容保持不变）
        /etc/storage/script/Sh45_wx_send.sh send_message "$title" "$content"
        # 记录推送成功到系统日志（日志中服务名使用 router的openvpn）
        logger -t "monitor_openvpn" "已发送微信推送: router的openvpn 公网地址和端口: -> ${ip} : ${wan_port}"
        logger -t "monitor_openvpn" "已发送微信推送: router的openvpn 出口地址和端口: -> ${wan_ip} : ${local_port}"
        # 更新推送记录（用于防重复）
        last_pushed_port="$local_port"
        last_push_time=$current_time
    else
        # 推送脚本不存在或无执行权限，记录错误
        logger -t "monitor_openvpn" "错误: 微信推送脚本不存在或无执行权限"
    fi
}

# 空行

# ----------------------------------------
# 步骤6：防火墙规则巡检与自动补充
# ----------------------------------------

# 定义 check_and_fix_firewall 函数
# 检查防火墙规则是否存在，缺失则自动补充
check_and_fix_firewall() {
    # 检查端口记录文件是否存在
    if [ ! -f "$PORT_FILE" ]; then
        # 文件不存在，说明还没有记录任何端口
        return
    fi

    # 读取端口号（去除空格和换行符）
    local expected_port=$(cat "$PORT_FILE" | tr -d ' \n')
    # 如果端口号为空，返回
    [ -z "$expected_port" ] && return

    # 检查规则是否存在
    # iptables -C 检查规则是否存在，不修改规则
    # 如果规则存在返回 0；不存在返回非 0
    if ! $IPTABLES -C INPUT -p tcp --dport "$expected_port" -j ACCEPT 2>/dev/null; then
        # 规则不存在，自动添加
        $IPTABLES -A INPUT -p tcp --dport "$expected_port" -j ACCEPT
        # 记录补充操作（日志中服务名使用 router的openvpn）
        logger -t "monitor_openvpn" "防火墙 INPUT 规则缺失，已自动补充: router的openvpn 出口地址端口: -> $expected_port"
    fi
}

# 空行

# ----------------------------------------
# 步骤7：处理 natmap 日志
# ----------------------------------------

# 定义 process_log 函数，核心处理逻辑
# 监控 natmap 日志，检测端口变化，更新防火墙规则，发送推送
process_log() {
    # 如果日志文件不存在，直接返回
    [ ! -f "$LOG" ] && return

    # 提取最新一条包含公网 IP 的日志行
    # tail -n 10 取文件最后 10 行
    # grep -E 使用扩展正则表达式匹配 IPv4 地址
    # tail -1 取最后一行（最新的一条）
    LINE=$(tail -n 10 "$LOG" | grep -E '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -1)
    [ -z "$LINE" ] && return

    # 解析日志行
    # 格式: 日期 时间 公网IP 公网端口 内网IP 本地端口 tcp 内网IP

    # 提取公网 IP（第3列）
    IP=$(echo "$LINE" | awk '{print $3}')

    # 提取公网端口（第4列）
    WAN_PORT=$(echo "$LINE" | awk '{print $4}')

    # 提取本地端口（优先第6列）
    LOCAL_PORT=$(echo "$LINE" | awk '{print $6}')
    # 兼容旧格式：第6列为空时取第5列
    [ -z "$LOCAL_PORT" ] && LOCAL_PORT=$(echo "$LINE" | awk '{print $5}')
    # 兜底：使用公网端口
    [ -z "$LOCAL_PORT" ] && LOCAL_PORT="$WAN_PORT"

    # 数据完整性检查
    [ -z "$IP" ] || [ -z "$WAN_PORT" ] && return

    # 端口无变化则返回
    [ "$LOCAL_PORT" = "$LAST_PORT" ] && return

    # 获取 WAN 口 IP
    WAN_IP=$(get_wan_ip)

    # 记录检测到端口变化（日志中服务名使用 router的openvpn）
    logger -t "monitor_openvpn" "检测到 router的openvpn 公网地址和端口变化: $LAST_PORT -> ${IP} : ${WAN_PORT}，等待20秒确认稳定..."
    logger -t "monitor_openvpn" "检测到 router的openvpn 出口地址和端口变化: $LAST_PORT -> ${WAN_IP} : ${LOCAL_PORT}，等待20秒确认稳定..."

    # 等待 20 秒确保端口稳定
    sleep 20

    # 二次验证：再次提取最新一条记录
    LINE2=$(tail -n 10 "$LOG" | grep -E '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -1)
    [ -z "$LINE2" ] && return

    # 解析第二次提取的日志行
    IP2=$(echo "$LINE2" | awk '{print $3}')
    WAN_PORT2=$(echo "$LINE2" | awk '{print $4}')
    LOCAL_PORT2=$(echo "$LINE2" | awk '{print $6}')
    [ -z "$LOCAL_PORT2" ] && LOCAL_PORT2=$(echo "$LINE2" | awk '{print $5}')
    [ -z "$LOCAL_PORT2" ] && LOCAL_PORT2="$WAN_PORT2"

    # 稳定性验证：端口和 IP 必须一致
    if [ "$LOCAL_PORT2" != "$LOCAL_PORT" ] || [ "$IP2" != "$IP" ]; then
        logger -t "monitor_openvpn" "router的openvpn 端口不稳定或 IP 变化，放弃本次更新"
        return
    fi

    # 删除旧规则
    if [ -n "$LAST_PORT" ]; then
        $IPTABLES -D INPUT -p tcp --dport "$LAST_PORT" -j ACCEPT 2>/dev/null
    fi

    # 添加新规则
    $IPTABLES -A INPUT -p tcp --dport "$LOCAL_PORT" -j ACCEPT

    # 写入端口记录文件
    echo "$LOCAL_PORT" > "$PORT_FILE"

    # 记录防火墙规则更新（日志中服务名使用 router的openvpn）
    logger -t "monitor_openvpn" "防火墙 INPUT 规则已添加: router的openvpn 出口地址端口: -> $LOCAL_PORT"

    # 发送微信推送
    send_push "$IP" "$WAN_PORT" "$LOCAL_PORT" "$WAN_IP"

    # 更新最后记录的端口
    LAST_PORT="$LOCAL_PORT"
}

# 空行

# ----------------------------------------
# 步骤8：启动延迟
# ----------------------------------------

# 记录脚本启动信息到系统日志（日志中服务名使用 router的openvpn）
logger -t "monitor_openvpn" "router的openvpn 监控脚本启动，等待 20 秒让 natmap 完成初始化..."

# 等待 20 秒让 natmap 有足够时间生成初始日志
sleep 20

# 空行

# ----------------------------------------
# 步骤9：主循环
# ----------------------------------------

# while true 无限循环，脚本持续运行
while true; do
    # 先执行规则巡检与修复（确保防火墙规则存在）
    check_and_fix_firewall
    # 再处理日志变化（检测端口变化并更新）
    process_log
    # 休眠 15 秒后进入下一轮循环
    sleep 15
done