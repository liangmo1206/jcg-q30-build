#!/bin/sh
# ============================================================
# gamefix - PassWall 游戏直连修复工具（JCG Q30 Pro / ImmortalWrt）
#
# 背景：PassWall 的 udp_node=tcp 会把「不在 chnroute 里的 UDP」塞进
#       TCP 隧道绕道境外节点。国服游戏的对战服常用阿里云新段
#       （如 8.133.124.0/23），2023 版 chnroute 未收录 → 被误判为
#       境外 → 延迟 400-999ms。往 direct_ip 加白名单即可修复。
#
# 用法：
#   gamefix catch            抓当前 UDP 连接，列出「被误判境外」的候选 IP
#   gamefix catch -w         持续观察（每 3 秒刷新，Ctrl+C 退出）
#   gamefix add 8.133.124.0/23   加入直连白名单并重启 PassWall
#   gamefix add 1.2.3.4 5.6.7.0/24
#   gamefix del 8.133.124.0/23
#   gamefix list             查看 direct_ip 现有内容
#   gamefix test 8.133.125.66    诊断某个 IP 走直连还是代理
#   gamefix status           查看 PassWall 代理模式与 ipset 规模
#
# 注意：写入的是 /usr/share/passwall/rules/direct_ip，落在 overlay，
#       sysupgrade 重刷会丢。本固件已内置 8.133.124.0/23；
#       自己后加的段请用 `gamefix list` 记下来，刷机后补回。
# ============================================================

RULES=/usr/share/passwall/rules/direct_ip
SET_WL=passwall_whitelist
SET_CN=passwall_chnroute
BAK=$RULES.gamefix.bak
CT_FILE=${CT_FILE:-/proc/net/nf_conntrack}

human() {
    awk -v b="$1" 'BEGIN{
        if (b >= 1048576) printf "%.1fMB", b/1048576
        else if (b >= 1024) printf "%.1fKB", b/1024
        else printf "%dB", b
    }'
}

info()  { printf '\033[36m%s\033[0m\n' "$*"; }
ok()    { printf '\033[32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[33m%s\033[0m\n' "$*"; }
err()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

[ "$(id -u)" = "0" ] || { err "请用 root 运行"; exit 1; }
[ -f "$RULES" ] || { err "找不到 $RULES（PassWall 没装？）"; exit 1; }

# 是否为合法 IPv4 / IPv4 CIDR
valid_ip() {
    case "$1" in
        *[!0-9./]*) return 1 ;;
    esac
    echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$' || return 1
    # 每段 <= 255
    echo "$1" | awk -F'[./]' '{
        for(i=1;i<=4;i++) if($i>255||$i=="") exit 1
        exit 0
    }'
}

# CIDR 用网络地址作为 ipset test 的样本（网络地址必然被该段覆盖）
test_addr() {
    echo "${1%%/*}"
}

usage() {
    cat <<'EOF'
gamefix - PassWall 游戏直连修复工具

  gamefix catch                抓当前 UDP 连接，列出「被误判境外」的候选 IP
  gamefix catch -w             持续观察（每 3 秒刷新，Ctrl+C 退出）
  gamefix add 8.133.124.0/23   加入直连白名单并重启 PassWall
  gamefix del 8.133.124.0/23   从白名单删除
  gamefix list                 查看 direct_ip 现有内容
  gamefix test 8.133.125.66    诊断单 IP 走直连还是代理
  gamefix status               查看代理模式、ipset 规模、进程

原理：udp_node=tcp 会把非 chnroute 的 UDP 塞进 TCP 隧道绕道境外。
      国服对战服若不在 chnroute，就会 400-999ms。加进 direct_ip
      （→ passwall_whitelist ipset）后即在 mangle 层 RETURN，走直连。
EOF
}

do_catch() {
    WATCH=$1
    while :; do
        [ "$WATCH" = "1" ] && clear
        info "=== 当前 UDP 连接（按字节降序，只看非 chnroute 目标）==="
        printf '%-18s %-7s %-9s %-11s %s\n' "目标IP" "端口" "包数" "字节" "判定"

        awk '$0 ~ / udp / {
            # nf_conntrack 一行有「去程+回程」两组 src/dst，只取第一组（去程）
            hs=hd=hdp=hp=hb=0; dst=""; dp=""; pk=0; by=0
            for (i=1; i<=NF; i++) {
                if ($i ~ /^src=/     && !hs)  { hs=1 }
                if ($i ~ /^dst=/     && !hd)  { dst = substr($i, 5); hd=1 }
                if ($i ~ /^dport=/   && !hdp) { dp  = substr($i, 7); hdp=1 }
                if ($i ~ /^packets=/ && !hp)  { pk  = substr($i, 9); hp=1 }
                if ($i ~ /^bytes=/   && !hb)  { by  = substr($i, 7); hb=1 }
            }
            if (dst == "") next
            # 过滤内网/组播/广播
            if (dst ~ /^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.|169\.254\.|255\.|0\.0\.0\.0$)/) next
            if (dst ~ /^(224\.|225\.|226\.|227\.|228\.|229\.|230\.|231\.|232\.|233\.|234\.|235\.|236\.|237\.|238\.|239\.)/) next
            b[dst] += by; p[dst] += pk; d[dst] = dp
        }
        END { for (k in b) printf "%s %s %s %s\n", b[k], p[k], k, d[k] }' "$CT_FILE" 2>/dev/null \
        | sort -rn | head -15 | while read -r bytes pkts ip dport; do
            if ipset test "$SET_WL" "$ip" >/dev/null 2>&1; then
                verdict="已白名单·直连"
            elif ipset test "$SET_CN" "$ip" >/dev/null 2>&1; then
                verdict="在chnroute·直连"
            else
                verdict="⚠ 未收录·走代理"
            fi
            printf '%-18s %-7s %-9s %-11s %s\n' "$ip" "$dport" "$pkts" "$(human "$bytes")" "$verdict"
        done

        echo
        info "提示：游戏正在运行时本表才有内容。若某 IP 被你确认是国服对战服，"
        info "     直接 gamefix add <IP>/32 加白名单。"
        [ "$WATCH" = "1" ] || break
        sleep 3
    done
}

do_test() {
    IP=$1
    valid_ip "$IP" || { err "不是合法 IPv4/CIDR: $IP"; exit 1; }
    A=$(test_addr "$IP")

    echo "--- 目标: $IP ---"
    V=""
    if ipset test "$SET_WL" "$A" >/dev/null 2>&1; then
        ok  "[1] 在 direct_ip 白名单（$SET_WL）"
        V=direct
    else
        echo "[1] 不在 direct_ip 白名单"
    fi

    if ipset test "$SET_CN" "$A" >/dev/null 2>&1; then
        ok  "[2] 在 chnroute 国内段"
        [ -z "$V" ] && V=direct
    else
        warn "[2] 不在 chnroute 国内段"
        [ -z "$V" ] && V=proxy
    fi

    echo "[3] mangle 里的白名单规则（命中即 RETURN，不打 mark）:"
    iptables -t mangle -L PSW -n -v 2>/dev/null | grep -m1 whitelist | sed 's/^/    /' \
        || echo "    （没找到，检查 passwall 是否运行）"

    echo "[4] 该 IP 的活跃连接实况（mark=1 表示已被送进代理）:"
    if grep -q "$A" "$CT_FILE" 2>/dev/null; then
        grep "$A" "$CT_FILE" 2>/dev/null | head -2 | sed 's/^/    /'
        M=$(grep "$A" "$CT_FILE" 2>/dev/null | grep -o 'mark=[0-9]*' | head -1)
        echo "    首个 mark: ${M:-无（直连不打 mark）}"
    else
        echo "    当前没有该 IP 的连接（游戏没在跑或已空闲）"
    fi

    echo
    case "$V" in
        direct) ok   "结论：走直连（命中白名单或国内段，不会被塞进 TCP 隧道）" ;;
        proxy)  warn "结论：走代理。若确认是国服对战服 → gamefix add $IP/32" ;;
        *)      echo "结论：未知" ;;
    esac
    echo
    echo "提示：不要用 'ip route get <ip> mark 1' 判断——mark 1 等于强行模拟代理态，"
    echo "      对任何非 chnroute 的 IP 都会返回 table 100，看不出白名单是否生效。"
}

do_add() {
    [ $# -gt 0 ] || { err "用法: gamefix add <IP或CIDR> [...]"; exit 1; }

    CNT=0; SKIP=0; BAD=0
    [ -f "$BAK" ] || cp "$RULES" "$BAK" 2>/dev/null

    for R in "$@"; do
        if ! valid_ip "$R"; then err "跳过非法项: $R"; BAD=$((BAD+1)); continue; fi
        if grep -qxF "$R" "$RULES"; then info "已存在，跳过: $R"; SKIP=$((SKIP+1)); continue; fi
        echo "$R" >> "$RULES" || { err "写入失败（只读文件系统？）: $R"; BAD=$((BAD+1)); continue; }
        ok "已追加: $R"
        CNT=$((CNT+1))
    done

    if [ "$CNT" -eq 0 ]; then
        warn "没有新增条目（新增0 跳过$SKIP 失败$BAD），不重启 PassWall"
        exit 0
    fi

    info "重启 PassWall 使白名单生效…"
    /etc/init.d/passwall restart >/dev/null 2>&1
    sleep 3
    # 等 ipset 被 iptables.sh 重新装载
    i=0
    while [ $i -lt 15 ]; do
        n=$(ipset list "$SET_WL" 2>/dev/null | grep -c '^[0-9]')
        [ "${n:-0}" -gt 0 ] && break
        sleep 1; i=$((i+1))
    done

    echo "--- 验证 ---"
    for R in "$@"; do
        valid_ip "$R" || continue
        A=$(test_addr "$R")
        if ipset test "$SET_WL" "$A" >/dev/null 2>&1; then
            ok "✔ $A 已在 $SET_WL"
        else
            err "✘ $A 仍不在 $SET_WL（PassWall 可能启动失败，看 logread）"
        fi
    done
    echo
    warn "提醒：此改动只存在于 overlay，sysupgrade 会丢。刷机后需重新 add。"
}

do_del() {
    [ $# -gt 0 ] || { err "用法: gamefix del <IP或CIDR>"; exit 1; }
    for R in "$@"; do
        if grep -qxF "$R" "$RULES"; then
            grep -vxF "$R" "$RULES" > "$RULES.tmp" && mv "$RULES.tmp" "$RULES"
            ok "已删除: $R"
        else
            warn "不存在，忽略: $R"
        fi
    done
    info "重启 PassWall…"
    /etc/init.d/passwall restart >/dev/null 2>&1
}

do_list() {
    echo "--- $RULES ---"
    nl -ba "$RULES" 2>/dev/null || cat "$RULES"
    echo
    echo "总行数: $(wc -l < "$RULES")"
    if [ -f "$BAK" ]; then echo "备份: $BAK"; fi
    return 0
}

do_status() {
    echo "=== PassWall 代理模式 ==="
    for k in tcp_node udp_node tcp_proxy_mode udp_proxy_mode acl_enable; do
        printf '  %-16s = %s\n' "$k" "$(uci get passwall.@global[0].$k 2>/dev/null)"
    done
    echo
    echo "=== ipset 规模 ==="
    for s in "$SET_CN" "$SET_WL"; do
        n=$(ipset list "$s" 2>/dev/null | grep -c '^[0-9]')
        printf '  %-20s %s 条\n' "$s" "${n:-N/A}"
    done
    echo
    echo "=== direct_ip 里的非 DNS 条目（真正的白名单段）==="
    grep -vE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$|^#' "$RULES" | sed 's/^/  /'
    echo
    echo "=== 进程 ==="
    ps w | grep -E 'xray|chinadns|dns2tcp' | grep -v grep | sed 's/^/  /'
}

case "$1" in
    catch)  [ "$2" = "-w" ] && do_catch 1 || do_catch 0 ;;
    add)    shift; do_add "$@" ;;
    del)    shift; do_del "$@" ;;
    list)   do_list ;;
    test)   do_test "$2" ;;
    status) do_status ;;
    *)      usage ;;
esac
