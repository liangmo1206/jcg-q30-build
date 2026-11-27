#!/bin/sh
# wifiset - 配置 MT7981 无线（MTK 私有驱动 .dat 体系）
#
# 背景：这套固件没有 UCI wireless，mtwifi.lua 只读 /etc/wireless/mediatek/*.dat，
#       LuCI 的无线页面因此不可用。改 WiFi 只能改 .dat，而 .dat 里
#       AuthMode 与 EncrypType 必须匹配：
#           AuthMode=WPA2PSK 且 EncrypType=NONE  ->  驱动生成 RSN IE 失败，
#           组播密钥退化成 WEP-40（内核报 GroupCipher=0x1），beacon 作废，
#           客户端扫不到或报「无法加入」。
#       本脚本把 SSID/密码/加密方式作为一个整体写入，杜绝这种半配置状态。
#
# 用法：
#   wifiset show                          查看两频段当前状态
#   wifiset set   <2g|5g|both> <SSID> <密码> [信道]
#   wifiset open  <2g|5g|both> <SSID> [信道]
#   wifiset chan  <2g|5g> <信道>
#
# 例：
#   wifiset set 5g ASUS_5G Tel38873150 149
#   wifiset set both ASUS Tel38873150
#   wifiset open 2g Guest

D2G=/etc/wireless/mediatek/mt7981.dbdc.b0.dat
D5G=/etc/wireless/mediatek/mt7981.dbdc.b1.dat
I2G=ra0
I5G=rax0

ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
err()  { printf '  \033[31m✘\033[0m %s\n' "$*" >&2; }
info() { printf '\033[36m%s\033[0m\n' "$*"; }

# 精确替换 KEY=VALUE 行；缺失则追加。用 ENVIRON 传值，避免密码里的
# & | \ 等字符被 sed/awk 解释。
set_kv() {
    _f=$1 _k=$2 _v=$3
    WK="$_k" WV="$_v" awk '
        BEGIN { k = ENVIRON["WK"]; v = ENVIRON["WV"]; done = 0 }
        index($0, k "=") == 1 { print k "=" v; done = 1; next }
        { print }
        END { if (!done) print k "=" v }
    ' "$_f" > "$_f.new" && mv "$_f.new" "$_f"
}

get_kv() {
    sed -n "s/^$2=//p" "$1" | head -1
}

resolve() {
    case "$1" in
        2g)   TGT="$D2G" ;;
        5g)   TGT="$D5G" ;;
        both) TGT="$D2G $D5G" ;;
        *)    err "频段只能是 2g / 5g / both"; exit 1 ;;
    esac
}

ifname_of() {
    [ "$1" = "$D2G" ] && echo "$I2G" || echo "$I5G"
}

backup() {
    B="/root/wifi-backup-$(date +%Y%m%d-%H%M%S).dat"
    cp "$1" "$B" || { err "备份失败：$1"; exit 1; }
    info "已备份：$B"
}

do_show() {
    for f in "$D2G" "$D5G"; do
        if [ "$f" = "$D2G" ]; then n=2.4G; i=$I2G; else n=5G; i=$I5G; fi
        printf '\n=== %s (%s) ===\n' "$n" "$i"
        printf '  SSID      : %s\n' "$(get_kv "$f" SSID1)"
        printf '  AuthMode  : %s\n' "$(get_kv "$f" AuthMode)"
        printf '  EncrypType: %s\n' "$(get_kv "$f" EncrypType)"
        printf '  Channel   : %s (AutoChannelSelect=%s)\n' \
            "$(get_kv "$f" Channel)" "$(get_kv "$f" AutoChannelSelect)"
        iwinfo "$i" info 2>/dev/null | sed -n 's/^ *\(ESSID\|Channel\|Bit Rate\|Encryption\):/\1:/p' | sed 's/^/  驱动: /'
    done
    echo
}

# 重启无线并校验：ESSID 生效 + 加密为 CCMP（不是 NONE）
apply_and_verify() {
    info "重启无线…"
    wifi down >/dev/null 2>&1
    sleep 2
    wifi up >/dev/null 2>&1

    FAIL=0
    for f in "$TGT"; do
        i=$(ifname_of "$f")
        want_ssid=$(get_kv "$f" SSID1)
        want_auth=$(get_kv "$f" AuthMode)

        n=0
        while [ $n -lt 25 ]; do
            cur=$(iwinfo "$i" info 2>/dev/null | sed -n 's/^ *ESSID: "\(.*\)"$/\1/p')
            [ "$cur" = "$want_ssid" ] && break
            sleep 1; n=$((n + 1))
        done
        if [ "$cur" != "$want_ssid" ]; then
            err "$i 未起来（期望 SSID=$want_ssid，实际=$cur）"
            FAIL=1; continue
        fi

        enc=$(iwinfo "$i" info 2>/dev/null | sed -n 's/^ *Encryption: //p')
        case "$want_auth" in
            OPEN)
                ok "$i 开放网络已生效（$enc）" ;;
            *)
                if echo "$enc" | grep -q 'CCMP'; then
                    ok "$i $want_ssid 已生效（$enc）"
                else
                    err "$i 加密异常：$enc（应含 CCMP；NONE 表示 RSN IE 生成失败）"
                    FAIL=1
                fi ;;
        esac
    done
    return $FAIL
}

rollback() {
    err "配置失败，回滚 .dat 并重启无线"
    for f in "$TGT"; do
        b=$(ls -t /root/wifi-backup-*.dat 2>/dev/null | head -1)
        [ -n "$b" ] && cp "$b" "$f"
    done
    wifi down >/dev/null 2>&1; sleep 2; wifi up >/dev/null 2>&1
    exit 1
}

do_set() {
    band=$1 ssid=$2 pass=$3 chan=$4
    [ -n "$ssid" ] || { err "缺少 SSID"; exit 1; }
    [ ${#ssid} -le 32 ] || { err "SSID 不能超过 32 字节"; exit 1; }
    if [ ${#pass} -lt 8 ] || [ ${#pass} -gt 63 ]; then
        err "WPA2 密码长度必须是 8-63 个字符"; exit 1
    fi
    resolve "$band"

    for f in "$TGT"; do
        backup "$f"
        set_kv "$f" SSID1 "$ssid"
        set_kv "$f" WPAPSK1 "$pass"
        # 这两项必须成对写，缺一个就会退化成 WEP
        set_kv "$f" AuthMode WPA2PSK
        set_kv "$f" EncrypType AES
        set_kv "$f" AutoChannelSelect 0
        if [ -n "$chan" ]; then
            set_kv "$f" Channel "$chan"
        elif [ "$(get_kv "$f" Channel)" = "0" ]; then
            [ "$f" = "$D2G" ] && set_kv "$f" Channel 11 || set_kv "$f" Channel 149
        fi
        info "$(basename "$f") -> SSID=$ssid Auth=WPA2PSK Enc=AES Ch=$(get_kv "$f" Channel)"
    done

    apply_and_verify || rollback
    do_show
}

do_open() {
    band=$1 ssid=$2 chan=$3
    [ -n "$ssid" ] || { err "缺少 SSID"; exit 1; }
    resolve "$band"
    for f in "$TGT"; do
        backup "$f"
        set_kv "$f" SSID1 "$ssid"
        # 开放网络必须同时清掉密码并置 OPEN/NONE，保持一致
        set_kv "$f" WPAPSK1 ""
        set_kv "$f" AuthMode OPEN
        set_kv "$f" EncrypType NONE
        set_kv "$f" AutoChannelSelect 0
        [ -n "$chan" ] && set_kv "$f" Channel "$chan"
        info "$(basename "$f") -> SSID=$ssid Auth=OPEN Enc=NONE"
    done
    apply_and_verify || rollback
    do_show
}

do_chan() {
    band=$1 chan=$2
    case "$band" in
        2g) TGT="$D2G"; case "$chan" in 1|2|3|4|5|6|7|8|9|10|11|12|13) ;; *) err "2.4G 信道取 1-13"; exit 1 ;; esac ;;
        5g) TGT="$D5G"; case "$chan" in 36|40|44|48|52|56|60|64|149|153|157|161|165) ;; *) err "5G 信道取值非法"; exit 1 ;; esac ;;
        *)  err "频段只能是 2g / 5g"; exit 1 ;;
    esac
    backup "$TGT"
    set_kv "$TGT" Channel "$chan"
    set_kv "$TGT" AutoChannelSelect 0
    info "信道已设为 $chan（AutoChannelSelect=0，避免被自动选择覆盖）"
    apply_and_verify || rollback
    do_show
}

case "$1" in
    show) do_show ;;
    set)  shift; do_set "$@" ;;
    open) shift; do_open "$@" ;;
    chan) shift; do_chan "$@" ;;
    *)
        cat <<'EOF'
wifiset - 配置本机无线（.dat 体系，此固件无 UCI wireless）

  wifiset show                          查看两频段状态
  wifiset set  <2g|5g|both> <SSID> <密码> [信道]
  wifiset open <2g|5g|both> <SSID> [信道]
  wifiset chan <2g|5g> <信道>

密码 8-63 字符。改完自动重启无线并校验加密是否为 CCMP，失败自动回滚。
EOF
        exit 1 ;;
esac
exit 0
