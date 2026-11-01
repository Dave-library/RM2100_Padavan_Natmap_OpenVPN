#!/bin/sh
# 这行是 shebang，指定使用 /bin/sh 作为解释器执行本脚本

# =============================================================================
# 脚本名称: stop_openvpn.sh
# 用途: 停止 router 上 OpenVPN 服务的 natmap 进程和 monitor_openvpn.sh
#       删除该服务曾经添加过的所有 INPUT 防火墙规则
#       从 natmap 日志提取所有历史端口，逐一删除确保无残留
# 目录: /etc/storage/bin/natmap/openvpn/
# 依赖: iptables, pgrep, logger, tee, date, grep, awk
# 备注: 日志文本中服务名统一使用 "router的openvpn"
# =============================================================================

# 空行

# ----------------------------------------
# 步骤1：定义日志文件路径
# ----------------------------------------

# 定义 BASE_DIR 变量，值为 natmap 根目录
BASE_DIR="/etc/storage/bin/natmap"

# 定义 OPENVPN_DIR 变量，值为 router 的 openvpn 服务目录
OPENVPN_DIR="$BASE_DIR/openvpn"

# 定义 OPENVPN_LOGS 变量，值为 router 的 openvpn 日志目录
OPENVPN_LOGS="$OPENVPN_DIR/logs"

# 创建日志目录（如果不存在）
mkdir -p "$OPENVPN_LOGS" 2>/dev/null

# 定义 LOG_FILE 变量，值为主控日志文件路径
LOG_FILE="$OPENVPN_LOGS/openvpn_ip_monitor.log"

# 定义 LOG_FILE_NATMAP 变量，值为 natmap 输出日志文件路径
LOG_FILE_NATMAP="$OPENVPN_LOGS/openvpn_natmap.log"

# 定义 CHANGED 变量，值为 0
# 操作标志，有任何实际操作时置为 1
CHANGED=0

# 空行

# ----------------------------------------
# 步骤2：辅助函数：删除指定端口的所有 INPUT 规则
# ----------------------------------------

# 定义 delete_port_rules 函数
# 参数: $1 = 端口号
delete_port_rules() {
    # 接收端口参数
    local port="$1"

    # while 循环持续删除该端口的所有规则
    # iptables -D 删除规则
    # 如果规则存在，删除成功返回 0
    # 如果规则不存在，删除失败返回非 0
    # 2>/dev/null 丢弃错误输出
    while iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; do
        # 删除成功，记录日志（日志中服务名使用 router的openvpn）
        # tee -a 同时输出到终端和追加到日志文件
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [stop_openvpn] 已删除 router的openvpn INPUT 规则（端口 $port）" | tee -a "$LOG_FILE"
        # 记录到系统日志
        logger -t "stop_openvpn" "已删除 router的openvpn INPUT 规则（端口 $port）"
        # 标记有操作发生
        CHANGED=1
    done
}

# 空行

# ----------------------------------------
# 步骤3：从端口记录文件删除
# ----------------------------------------

# 定义 PORT_FILE 变量，值为端口记录文件路径
PORT_FILE="/tmp/natmap_openvpn_port"

# 如果端口记录文件存在
if [ -f "$PORT_FILE" ]; then
    # 读取文件中的所有端口，排序去重后逐个删除
    for port in $(cat "$PORT_FILE" | sort -u); do
        delete_port_rules "$port"
    done
    # 删除端口记录文件
    rm -f "$PORT_FILE"
fi

# 空行

# ----------------------------------------
# 步骤4：从 natmap 日志提取所有端口并删除
# ----------------------------------------

# 如果 natmap 日志文件存在
if [ -f "$LOG_FILE_NATMAP" ]; then
    # ---- 提取第5列（本地端口） ----
    grep -E '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ [0-9]+' "$LOG_FILE_NATMAP" | \
    awk '{print $5}' | while read port; do
        [ -z "$port" ] && continue
        delete_port_rules "$port"
    done

    # ---- 备选：提取第3列（公网端口，兼容旧日志格式） ----
    grep -E '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ [0-9]+' "$LOG_FILE_NATMAP" | \
    awk '{print $3}' | while read port; do
        [ -z "$port" ] && continue
        delete_port_rules "$port"
    done
else
    # natmap 日志文件不存在，记录警告
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [stop_openvpn] 警告: router的openvpn natmap 日志文件不存在，无法提取端口" | tee -a "$LOG_FILE"
    logger -t "stop_openvpn" "警告: router的openvpn natmap 日志文件不存在"
fi

# 空行

# ----------------------------------------
# 步骤5：停止 natmap 进程
# ----------------------------------------

# pgrep -f 查找匹配完整命令行的进程
OPENVPN_PID=$(pgrep -f "natmap.*172.16.10.1.*61194")

# 如果找到 PID（非空）
if [ -n "$OPENVPN_PID" ]; then
    # kill 杀死进程
    kill $OPENVPN_PID 2>/dev/null
    # 记录日志（日志中服务名使用 router的openvpn）
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [stop_openvpn] 已停止 router的openvpn natmap (PID: $OPENVPN_PID)" | tee -a "$LOG_FILE"
    logger -t "stop_openvpn" "已停止 router的openvpn natmap (PID: $OPENVPN_PID)"
    CHANGED=1
else
    # 进程未运行
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [stop_openvpn] router的openvpn natmap 未运行，无需停止" | tee -a "$LOG_FILE"
    logger -t "stop_openvpn" "router的openvpn natmap 未运行，无需停止"
fi

# 空行

# ----------------------------------------
# 步骤6：停止 monitor_openvpn.sh 进程
# ----------------------------------------

MONITOR_PID=$(pgrep -f "monitor_openvpn.sh")

if [ -n "$MONITOR_PID" ]; then
    kill $MONITOR_PID 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [stop_openvpn] 已停止 monitor_openvpn.sh (PID: $MONITOR_PID)" | tee -a "$LOG_FILE"
    logger -t "stop_openvpn" "已停止 monitor_openvpn.sh (PID: $MONITOR_PID)"
    CHANGED=1
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [stop_openvpn] monitor_openvpn.sh 未运行，无需停止" | tee -a "$LOG_FILE"
    logger -t "stop_openvpn" "monitor_openvpn.sh 未运行，无需停止"
fi

# 空行

# ----------------------------------------
# 步骤7：清理锁文件
# ----------------------------------------

# 删除锁文件，防止下次启动时认为脚本还在运行
rm -f /tmp/monitor_openvpn.lock

# 空行

# ----------------------------------------
# 步骤8：输出总结信息
# ----------------------------------------

if [ $CHANGED -eq 1 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [stop_openvpn] router的openvpn 的 natmap 相关进程处理完成，添加的防火墙规则已删除" | tee -a "$LOG_FILE"
    logger -t "stop_openvpn" "router的openvpn 的 natmap 相关进程处理完成，添加的防火墙规则已删除"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [stop_openvpn] router的openvpn 相关进程未运行，无需处理" | tee -a "$LOG_FILE"
    logger -t "stop_openvpn" "router的openvpn 相关进程未运行，无需处理"
fi

# 脚本正常结束