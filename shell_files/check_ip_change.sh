#!/bin/sh
# 这行是 shebang，指定使用 /bin/sh 作为解释器执行本脚本

# =============================================================================
# 脚本名称: check_ip_change.sh
# 功能: 监控 WAN IP 变化，自动重启 router的openvpn natmap
#       进程保活、日志轮转（每天4:00~6:00检查，超过7天或大于1MB清空）
# 目录: /etc/storage/bin/natmap/
# 说明: 本脚本是核心主控脚本，需常驻后台运行，开机自启
# 备注: 日志文本中服务名统一使用 "router的openvpn"；微信推送标题保持 [OPENVPN] 不变
# =============================================================================

# 输出启动提示到终端
echo "IP 变化检测脚本已启动 (PID: $$)，正在后台监控 WAN IP..."

# 获取脚本启动时间戳，用于判断脚本是否刚启动
SCRIPT_START_TIME=$(date +%s)

# 导出为环境变量，供函数内部使用
export SCRIPT_START_TIME

# 空行

# ----------------------------------------
# 步骤1：定义目录与日志路径
# ----------------------------------------

# 定义 BASE_DIR 变量，值为 natmap 根目录
BASE_DIR="/etc/storage/bin/natmap"

# 定义 OPENVPN_DIR 变量，值为 router 的 openvpn 服务目录
OPENVPN_DIR="$BASE_DIR/openvpn"

# 定义 OPENVPN_LOGS 变量，值为 router 的 openvpn 日志目录
OPENVPN_LOGS="$OPENVPN_DIR/logs"

# 创建日志目录（如果不存在）
mkdir -p "$OPENVPN_LOGS" 2>/dev/null

# 定义 OPENVPN_MAIN 变量，值为 router 的 openvpn 主控日志路径
OPENVPN_MAIN="$OPENVPN_LOGS/openvpn_ip_monitor.log"

# 定义 OPENVPN_NATMAP 变量，值为 router 的 openvpn natmap 输出日志路径
OPENVPN_NATMAP="$OPENVPN_LOGS/openvpn_natmap.log"

# 写入启动信息到主控日志
echo "$(date '+%Y-%m-%d %H:%M:%S') - IP 变化检测脚本已启动" | tee -a "$OPENVPN_MAIN"

# 写入系统日志
logger -t "check_ip" "IP 变化检测脚本已启动 (PID: $$)"

# 空行

# ----------------------------------------
# 步骤2：函数定义
# ----------------------------------------

# ---------- 2.1 获取当前 WAN IP ----------

# 从 ppp0 接口提取公网 IP
get_wan_ip() {
    # ifconfig 显示 ppp0 网络接口信息
    # grep 'inet addr' 过滤包含 IP 地址的行
    # awk -F: 以冒号作为分隔符，取第2字段
    # 第二个 awk 取第1个单词（纯 IP 地址）
    ifconfig ppp0 2>/dev/null | grep 'inet addr' | awk -F: '{print $2}' | awk '{print $1}'
}

# 空行

# ---------- 2.2 不可达计数器（每日重置） ----------

# 统计不可达事件的次数，每天自动重置
# 参数: $1 = 服务标识
get_unreach_count() {
    # 第一个参数保存到 service 变量
    local service="$1"
    # 计数器文件路径
    local COUNT_FILE="/etc/storage/natmap_unreach_${service}.txt"
    # 获取当天日期
    TODAY=$(date '+%Y-%m-%d')

    # 计数器文件不存在，创建并返回 1
    if [ ! -f "$COUNT_FILE" ]; then
        echo "$TODAY|1" > "$COUNT_FILE"
        echo "1"
        return
    fi

    # 读取保存的日期和计数
    SAVED_DATE=$(cut -d'|' -f1 "$COUNT_FILE")
    SAVED_COUNT=$(cut -d'|' -f2 "$COUNT_FILE")

    # 日期不同，重置为今天和计数 1
    if [ "$SAVED_DATE" != "$TODAY" ]; then
        echo "$TODAY|1" > "$COUNT_FILE"
        echo "1"
    else
        # 日期相同，计数加 1
        NEW_COUNT=$((SAVED_COUNT + 1))
        echo "$TODAY|$NEW_COUNT" > "$COUNT_FILE"
        echo "$NEW_COUNT"
    fi
}

# 空行

# ---------- 2.3 识别 IP 变化原因 ----------

# 根据系统运行状态判断本次 IP 变化的原因
get_change_reason() {
    # 获取系统已运行的秒数
    local uptime_seconds=$(cat /proc/uptime | awk '{print $1}' | cut -d. -f1)
    # 当前小时
    local current_hour=$(date +%H)
    # 当前分钟
    local current_min=$(date +%M)
    # 转换为当天分钟数（10# 强制十进制）
    local current_time=$((10#$current_hour * 60 + 10#$current_min))
    # 系统日志文件路径
    local log_file="/tmp/syslog.log"
    # 脚本启动时间，未定义则用当前时间
    local script_start_time=${SCRIPT_START_TIME:-$(date +%s)}
    # 当前时间戳
    local current_time_stamp=$(date +%s)
    # 脚本已运行秒数
    local script_age=$((current_time_stamp - script_start_time))

    # 场景1：脚本刚启动且系统刚重启
    if [ $script_age -lt 120 ] && [ $uptime_seconds -lt 600 ]; then
        # 判断是否在凌晨 3:00~3:05
        if [ $current_time -ge 180 ] && [ $current_time -le 185 ]; then
            echo "定时重启（凌晨 3:00）"
        else
            echo "手动重启（SSH/Web 触发）"
        fi
        return
    fi

    # 场景1备用：仅依赖系统运行时间
    if [ $uptime_seconds -lt 600 ]; then
        if [ $current_time -ge 180 ] && [ $current_time -le 185 ]; then
            echo "定时重启（凌晨 3:00）"
        else
            echo "手动重启（SSH/Web 触发）"
        fi
        return
    fi

    # 场景2：PPPoE 断线重连
    if [ -f "$log_file" ]; then
        # 搜索最近 60 秒内的 pppd 断线记录
        local pppd_down=$(grep "pppd" "$log_file" | grep -E "LCP down|disconnected" | tail -1 | awk '{print $1" "$2}' | date -d "- 60 seconds" 2>/dev/null)
        if [ -n "$pppd_down" ]; then
            echo "网络断线重连（PPPoE 链路中断）"
            return
        fi
    fi

    # 场景3：运营商例行维护（凌晨 2:00~5:00）
    if [ $current_time -ge 120 ] && [ $current_time -le 300 ]; then
        echo "运营商例行维护（凌晨时段重拨）"
        return
    fi

    # 场景4：兜底
    echo "外网链路变化，重新拨号"
}

# 空行

# ---------- 2.4 日志轮转（每天 4:00~6:00 检查） ----------

# 检查日志文件是否超过 7 天或大于 1MB，满足条件则清空
rotate_logs() {
    # 标志文件：当天已轮转则跳过
    local flag_file="/tmp/natmap_log_rotate_done_$(date '+%Y%m%d')"
    if [ -f "$flag_file" ]; then
        return
    fi

    # 只在 4:00~6:00 之间执行
    local hour=$(date +%H)
    if [ $hour -lt 4 ] || [ $hour -ge 6 ]; then
        return
    fi

    # 创建标志文件，防止当天重复执行
    touch "$flag_file"

    # 遍历 router 的 openvpn 主控日志和 natmap 日志
    for log in "$OPENVPN_MAIN" "$OPENVPN_NATMAP"; do
        if [ -f "$log" ]; then
            # 超过 7 天则清空
            if find "$log" -mtime +7 2>/dev/null | grep -q .; then
                > "$log"
                echo "$(date '+%Y-%m-%d %H:%M:%S') - 日志轮转：已清空 $log（超过7天）" >> "$OPENVPN_MAIN"
                logger -t "check_ip" "日志轮转：已清空 $log（超过7天）"
            # 大于 1MB 则清空
            elif [ $(stat -c %s "$log" 2>/dev/null) -gt 1048576 ]; then
                > "$log"
                echo "$(date '+%Y-%m-%d %H:%M:%S') - 日志轮转：已清空 $log（大于1MB）" >> "$OPENVPN_MAIN"
                logger -t "check_ip" "日志轮转：已清空 $log（大于1MB）"
            fi
        fi
    done
}

# 空行

# ---------- 2.5 确保 router 的 openvpn 服务运行 ----------

# 检查 natmap 进程，不存在时尝试启动；不可达时进入 6 小时冷却
ensure_openvpn() {
    # 当前时间戳
    local current_time=$(date +%s)

    # 冷却检查：还在冷却期内则跳过
    if [ $current_time -lt $next_ping_openvpn ]; then
        # 计算剩余冷却分钟数
        local remain_min=$(( ($next_ping_openvpn - $current_time) / 60 ))
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [ensure_openvpn] router的openvpn 冷却中，跳过检测 (剩余 ${remain_min} 分钟)" >> "$OPENVPN_MAIN"
        return
    fi

    # 记录被调用
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [ensure_openvpn] router的openvpn 被调用" >> "$OPENVPN_MAIN"

    # 检查 natmap 进程是否存在
    if ! pgrep -f "natmap.*172.16.10.1.*61194" > /dev/null; then
        # 不存在，先 ping 目标 IP
        if ping -c 1 -W 2 172.16.10.1 > /dev/null 2>&1; then
            # 可达，清除冷却
            next_ping_openvpn=0

            # 记录启动信息（日志中服务名使用 router的openvpn）
            local msg="router的openvpn IP 可达，启动 router的openvpn natmap 和 monitor"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" | tee -a "$OPENVPN_MAIN"
            logger -t "check_ip" "$msg"

            # 启动 natmap
            /etc/storage/bin/natmap/natmap -d -s turn.cloudflare.com -h baidu.com -b 0 -t 172.16.10.1 -p 61194 2>&1 | while read line; do
                echo "$(date '+%Y-%m-%d %H:%M:%S') $line"
            done >> "$OPENVPN_NATMAP" &

            # 等待 natmap 初始化
            sleep 5

            # 如果 monitor 未运行则启动
            if ! pgrep -f "monitor_openvpn.sh" > /dev/null; then
                /etc/storage/bin/natmap/openvpn/monitor_openvpn.sh > "$OPENVPN_LOGS/openvpn_debug.log" 2>&1 &
                echo "$(date '+%Y-%m-%d %H:%M:%S') - 已启动 monitor_openvpn.sh" >> "$OPENVPN_MAIN"
            fi
        else
            # 不可达：进入 6 小时冷却
            next_ping_openvpn=$((current_time + COOLDOWN_SECONDS))
            # 格式化下次检测时间
            local next_time_str=$(date -d "@$next_ping_openvpn" '+%Y-%m-%d %H:%M:%S')
            # 记录日志（日志中服务名使用 router的openvpn）
            local msg="router的openvpn IP 不可达，下次检测: $next_time_str"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" | tee -a "$OPENVPN_MAIN"
            logger -t "check_ip" "$msg"

            # 获取不可达计数并发送微信推送（推送标题保持 [OPENVPN] 不变）
            local COUNT=$(get_unreach_count "openvpn")
            local title="[OPENVPN] 端口更新失败 (第${COUNT}条)"
            local content="原因: 目标 IP 172.16.10.1 无法 ping 通
本地地址: 172.16.10.1:61194
下次检测: ${next_time_str} (约 6 小时后)"
            /etc/storage/script/Sh45_wx_send.sh send_message "$title" "$content"
        fi
    else
        # 进程存在，清除冷却
        next_ping_openvpn=0
        # 记录进程存在（日志中服务名使用 router的openvpn）
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [ensure_openvpn] router的openvpn 进程存在" >> "$OPENVPN_MAIN"
    fi
}

# 空行

# ---------- 2.6 IP 变化时重启 natmap ----------

# IP 变化时重启 natmap，并将原因写入临时文件供 monitor 读取
restart_natmap() {
    # 目标 IP
    local target_ip="172.16.10.1"
    # 目标端口
    local target_port="61194"

    # 获取变化原因
    local reason=$(get_change_reason)
    # 组装日志消息
    local msg="IP变化原因: $reason"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" | tee -a "$OPENVPN_MAIN"
    logger -t "check_ip" "$msg"

    # 写入原因文件供 monitor 读取
    echo "$reason" > /tmp/ip_change_reason_openvpn

    # 检查目标 IP 是否可达
    if ! ping -c 1 -W 2 "$target_ip" > /dev/null 2>&1; then
        # 不可达，记录日志
        local msg="目标 $target_ip 不可达，放弃重启 router的openvpn natmap"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" | tee -a "$OPENVPN_MAIN"
        logger -t "check_ip" "$msg"

        # 计算下次检测时间
        local current_time=$(date +%s)
        local next_check_time=$((current_time + 21600))
        local next_check_str=$(date -d "@$next_check_time" '+%Y-%m-%d %H:%M:%S')
        # 获取不可达计数
        local COUNT=$(get_unreach_count "openvpn")

        # 发送微信推送（推送标题保持 [OPENVPN] 不变）
        local title="[OPENVPN] 端口更新失败 (第${COUNT}条)"
        local content="原因: 目标 IP ${target_ip} 无法 ping 通
本地地址: ${target_ip}:${target_port}
下次检测: ${next_check_str} (约 6 小时后)"
        /etc/storage/script/Sh45_wx_send.sh send_message "$title" "$content"
        return
    fi

    # 目标可达，记录重启日志（日志中服务名使用 router的openvpn）
    local msg="IP变化，重启 router的openvpn natmap (${target_ip}:${target_port})"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" | tee -a "$OPENVPN_MAIN"
    logger -t "check_ip" "$msg"

    # 停止旧 natmap 进程
    for pid in $(pgrep -f "natmap.*$target_ip.*$target_port"); do
        kill $pid 2>/dev/null
        local kill_msg="停止旧 router的openvpn natmap 进程 PID=$pid"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $kill_msg" | tee -a "$OPENVPN_MAIN"
        logger -t "check_ip" "$kill_msg"
    done

    # 等待 1 秒确保进程退出
    sleep 1

    # 启动新 natmap
    /etc/storage/bin/natmap/natmap -d -s turn.cloudflare.com -h baidu.com -b 0 -t "$target_ip" -p "$target_port" 2>&1 | while read line; do
        echo "$(date '+%Y-%m-%d %H:%M:%S') $line"
    done >> "$OPENVPN_NATMAP" &

    # 记录启动完成（日志中服务名使用 router的openvpn）
    local start_msg="已启动新 router的openvpn natmap (${target_ip}:${target_port})"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $start_msg" | tee -a "$OPENVPN_MAIN"
    logger -t "check_ip" "$start_msg"
}

# 空行

# ---------- 2.7 获取稳定 WAN IP ----------

# 连续两次获取 WAN IP，相同才确认，避免临时波动
get_stable_wan_ip() {
    # 第一次获取
    local ip1=$(get_wan_ip)
    # 为空则失败
    [ -z "$ip1" ] && return 1
    # 等待 5 秒
    sleep 5
    # 第二次获取
    local ip2=$(get_wan_ip)
    # 两次相同则输出并成功
    if [ "$ip1" = "$ip2" ]; then
        echo "$ip1"
        return 0
    else
        return 1
    fi
}

# 空行

# ----------------------------------------
# 步骤3：冷却与状态变量
# ----------------------------------------

# 不可达冷却时间：21600 秒（6 小时）
COOLDOWN_SECONDS=21600

# 下次允许 ping router的openvpn 的时间戳，0 表示无冷却
next_ping_openvpn=0

# 空行

# ----------------------------------------
# 步骤4：主循环
# ----------------------------------------

# 上次记录的 WAN IP，用于检测变化
last_ip_openvpn=""

# while true 无限循环，脚本持续运行
while true; do
    # 执行保活检测
    ensure_openvpn

    # 每日执行一次日志轮转（函数内部控制频率）
    rotate_logs

    # 获取稳定 WAN IP
    stable_ip=$(get_stable_wan_ip)
    # 获取失败则等待 30 秒后继续
    if [ -z "$stable_ip" ]; then
        sleep 30
        continue
    fi

    # 检查 router的openvpn natmap 进程是否存在
    if pgrep -f "natmap.*172.16.10.1.*61194" > /dev/null; then
        # 进程存在，检查 IP 是否变化
        if [ "$stable_ip" != "$last_ip_openvpn" ]; then
            # IP 变化，重启 natmap
            restart_natmap
            # 更新记录
            last_ip_openvpn="$stable_ip"
        fi
    else
        # 进程不存在，清空记录
        last_ip_openvpn=""
    fi

    # 等待 30 秒再进入下一轮循环
    sleep 30
done

# 脚本结束