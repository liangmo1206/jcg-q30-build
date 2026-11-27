#!/bin/sh
# q30check - JCG Q30 Pro 硬件指纹校验
#
# 用途：在【要刷的那台机器上、跑着旧固件时】先验硬件，确认是 Q30 Pro 的
#       标准布局，再执行 sysupgrade。不以设备名为唯一依据，主要看硬件事实。
#
# 为什么不能只看设备名：同一块板子在不同固件里的 compatible 写法不一样
#   ImmortalWrt 21.02        jcg,q30
#   雕牌 Kwrt 25.12          jcg,q30-pro       <- 连字符（实测这台备用机）
#   部分第三方固件            jcg,q30_pro       <- 下划线
#   ImmortalWrt 23.05 分支    jcg,q30-ubootmod  <- 另一套布局，绝不能刷
# 而各固件的 /proc/mtd 视图也不同（有没有 08000000 的总设备、分区名大小写
# 也不统一），所以这里按【分区名】比对，不按 mtd 序号比对。
#
# 实测样本：ImmortalWrt 21.02（有 spi0.0 总设备、BL2/FIP 大写）
#           Kwrt 25.12（无总设备、bl2/fip 小写）—— 两者分区大小完全一致
#
# 用法：  sh q30check          # 校验，通过返回 0
#         sh q30check -v       # 额外打印原始分区表
# 退出码：0 匹配可刷；1 不匹配，勿刷
#
# 测试钩子（只为本地自测，正常使用不必设置）：
#   Q30_MTD=/tmp/fake_mtd Q30_COMPAT=/tmp/fake_compat sh q30check

VERBOSE=0
[ "$1" = "-v" ] && VERBOSE=1

RAW=${Q30_MTD:-/proc/mtd}
COMPAT_F=${Q30_COMPAT:-/proc/device-tree/compatible}

FAIL=0
note() { printf '  %-10s %s\n' "$1" "$2"; }
bad()  { FAIL=$((FAIL + 1)); }

# 标准布局：分区名(小写):大小
EXPECT="bl2:00100000 u-boot-env:00080000 factory:00200000 fip:00200000 ubi:06e80000"
WHOLE=08000000

echo "== JCG Q30 Pro hardware check =="

# ---------- 解析分区表 ----------
# /proc/mtd 每行形如：mtd0: 00100000 00020000 "bl2"
PARTS=$(awk '/^mtd[0-9]+:/{n=$4; gsub(/"/,"",n); print tolower(n), $2, $3}' "$RAW" 2>/dev/null)
if [ -z "$PARTS" ]; then
	note "MTD" "cannot read $RAW"
	bad
fi
psize() { echo "$PARTS" | awk -v k="$1" '$1==k{print $2}' | head -1; }

# ---------- 1. SoC ----------
COMPAT=$(tr '\0' ' ' < "$COMPAT_F" 2>/dev/null)
case "$COMPAT" in
	*mediatek,mt7981*) note "SoC" "mediatek,mt7981  OK" ;;
	*)                 note "SoC" "NOT MT7981 -> ${COMPAT:-read-failed}"; bad ;;
esac

# ---------- 2. 设备名（记录 + 拦 ubootmod） ----------
BOARD=${COMPAT%% *}
case "$BOARD" in
	*ubootmod*)                      note "Board" "$BOARD  ubootmod - NOT supported"; bad ;;
	jcg,q30|jcg,q30_pro|jcg,q30-pro) note "Board" "$BOARD  OK (known alias)" ;;
	*)                               note "Board" "${BOARD:-unknown}  unfamiliar name, layout decides below" ;;
esac

# ---------- 3. 分区名齐全 ----------
MISS=""
for e in $EXPECT; do
	n=${e%%:*}
	[ -n "$(psize "$n")" ] || MISS="$MISS $n"
done
if [ -z "$MISS" ]; then
	note "Layout" "standard bl2/u-boot-env/factory/fip/ubi  OK"
else
	note "Layout" "missing partition:$MISS"
	bad
fi

# ---------- 4. 各分区大小 ----------
SZFAIL=""
for e in $EXPECT; do
	n=${e%%:*}; want=${e#*:}; got=$(psize "$n")
	[ -z "$got" ] && continue
	[ "$got" = "$want" ] || SZFAIL="$SZFAIL $n=$got(want $want)"
done
if [ -z "$SZFAIL" ]; then
	note "MTD" "partition sizes match  OK"
else
	note "MTD" "size mismatch:$SZFAIL"
	bad
fi

# ---------- 5. NAND 总容量 ----------
ATWHOLE=$(echo "$PARTS" | awk -v w="$WHOLE" '$2==w{print $1}' | head -1)
if [ -n "$ATWHOLE" ]; then
	note "NAND" "128MB ($WHOLE)  OK"
elif [ "$(psize ubi)" = "06e80000" ]; then
	note "NAND" "128MB (inferred, ubi=110.5MiB)  OK"
else
	note "NAND" "cannot confirm 128MB (no whole-chip entry, ubi=$(psize ubi))"
	bad
fi

# ---------- 6. 内存（仅记录，不参与判定） ----------
MEMKB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
case "$MEMKB" in
	''|*[!0-9]*) note "RAM" "read failed" ;;
	*) if [ "$MEMKB" -gt 400000 ]; then
		note "RAM" "512MB variant (${MEMKB} kB)"
	   else
		note "RAM" "256MB variant (${MEMKB} kB)"
	   fi ;;
esac

[ "$VERBOSE" = 1 ] && {
	echo "  --- raw ---"
	echo "$PARTS" | sed 's/^/  /'
	echo "  compatible: $COMPAT"
}

echo
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: MATCH - hardware verified, safe to sysupgrade"
	exit 0
else
	echo "RESULT: MISMATCH ($FAIL check(s) failed) - DO NOT flash this image"
	exit 1
fi
