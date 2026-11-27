#!/bin/sh
# q30check - JCG Q30 Pro 硬件指纹校验
#
# 目的：sysupgrade 只认设备名（board_name），但同名设备可能来自不同固件，
# 而不同固件对同一块板子的命名并不统一。刷错分区布局的镜像会变砖。
# 本脚本不看名字，直接读硬件事实：SoC、NAND 容量、MTD 分区表。
#
# 判定依据来自两台已验证的实机（256M / 512M 内存版本），两者 NAND 分区表
# 完全一致，唯一差别是内存容量。
#
# 用法：  sh q30check          # 校验，通过返回 0
#         sh q30check -v       # 额外打印原始信息

VERBOSE=0
[ "$1" = "-v" ] && VERBOSE=1

# 已验证的 MTD 分区表指纹（大小:擦除块:名字，按 mtd 序号排列）
EXPECT="08000000:00020000:spi0.0 00100000:00020000:BL2 00080000:00020000:u-boot-env 00200000:00020000:Factory 00200000:00020000:FIP 06e80000:00020000:ubi"

FAIL=0
note() { printf '  %-10s %s\n' "$1" "$2"; }
bad()  { FAIL=$((FAIL + 1)); }

echo "== JCG Q30 Pro hardware check =="

# ---------- 1. SoC ----------
COMPAT=$(tr '\0' ' ' < /proc/device-tree/compatible 2>/dev/null)
case "$COMPAT" in
	*mediatek,mt7981*) note "SoC" "mediatek,mt7981  OK" ;;
	*)                 note "SoC" "NOT MT7981 -> $COMPAT"; bad ;;
esac

# ---------- 2. 分区布局类型 ----------
# ubootmod 是另一套布局（BL2/FIP 位置不同），交叉刷写会变砖。
case "$COMPAT" in
	*ubootmod*) note "Layout" "ubootmod - NOT supported by this image"; bad ;;
	*)          note "Layout" "standard - OK" ;;
esac

# ---------- 3. NAND 容量 ----------
NAND=$(awk '/^mtd0:/{print $2}' /proc/mtd 2>/dev/null)
if [ "$NAND" = "08000000" ]; then
	note "NAND" "128MB ($NAND)  OK"
else
	note "NAND" "expected 128MB, got ${NAND:-read-failed}"
	bad
fi

# ---------- 4. MTD 分区表指纹 ----------
ACTUAL=$(awk '/^mtd[0-9]+:/{gsub(/"/,""); print $2":"$3":"$4}' /proc/mtd 2>/dev/null | tr '\n' ' ' | sed -e 's/ *$//')
if [ "$ACTUAL" = "$EXPECT" ]; then
	note "MTD" "partition table matches  OK"
else
	note "MTD" "partition table MISMATCH"
	[ "$VERBOSE" = 1 ] && {
		echo "    期望: $EXPECT"
		echo "    实际: $ACTUAL"
	}
	bad
fi

# ---------- 5. 内存容量（仅记录，不参与判定） ----------
MEMKB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
if [ -n "$MEMKB" ]; then
	if [ "$MEMKB" -gt 400000 ]; then
		note "RAM" "512MB variant (${MEMKB} kB)"
	else
		note "RAM" "256MB variant (${MEMKB} kB)"
	fi
else
	note "RAM" "read failed"
fi

# ---------- 6. 当前系统与设备名（仅记录） ----------
CUR=$(cat /tmp/sysinfo/board_name 2>/dev/null)
[ -n "$CUR" ] && note "Board" "$CUR"

echo
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: MATCH - hardware verified, safe to sysupgrade"
	exit 0
else
	echo "RESULT: MISMATCH ($FAIL check(s) failed) - DO NOT flash this image"
	exit 1
fi
