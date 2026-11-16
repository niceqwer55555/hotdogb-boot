#!/usr/bin/env bash
# 独立编译 sm8150 内核（只编内核，不跑 brunch / 不重编 system）
# 用法: build-kernel.sh [defconfig|dtbs|image|all] [PROFILE]
# 所有路径相对工程根，工具链由 fetch-toolchain.sh 归一化到 toolchain/
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/config/build.env"
[[ -f "$ROOT/config/local.env" ]] && source "$ROOT/config/local.env"

STAGE="${1:-all}"
PROFILE="${2:-$PROFILE}"
K="$ROOT/$KERNEL_DIR"
OBJ="$ROOT/out"
TC="$ROOT/toolchain"
LOG="$ROOT/build-kernel.log"

log() { printf '\033[1;32m[kernel]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[kernel] 失败:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$TC/.ready" ]] || die "工具链未就绪，请先运行 scripts/fetch-toolchain.sh"
[[ -d "$K/arch/arm64" ]] || die "内核源码缺失: $K"

# ------------------------------------------------- Windows 大小写不敏感补齐
# Linux 内核里有一批「仅靠大小写区分」的源/头文件，例如
#   net/netfilter/xt_DSCP.c (target)   vs  xt_dscp.c (match)
#   include/uapi/linux/netfilter_ipv4/ipt_TTL.h  vs  ipt_ttl.h
# Windows/NTFS 大小写不敏感，提交时它们会合并成一个，Linux 上编译就会报
# "No rule to make target 'net/netfilter/xt_DSCP.o'" 或找不到头文件。
# 大写原件保存在 patches/casefix/（该目录内只有大写版本，Windows 也能共存），
# 编译前只在大小写敏感的文件系统上还原，绝不覆盖小写版本。
CASEFIX="$ROOT/patches/casefix"
case "$(uname -s)" in
  Linux*)
    if [[ -d "$CASEFIX" ]]; then
      while IFS= read -r -d '' src; do
        rel="${src#$CASEFIX/}"
        case "$rel" in
          *.md) continue ;;   # README 等说明文档不是源码，别复制成 kernel/README.md
        esac
        dst="$K/$rel"
        if [[ ! -e "$dst" ]]; then
          mkdir -p "$(dirname "$dst")"
          cp "$src" "$dst"
          log "casefix: 还原 $rel"
        fi
      done < <(find "$CASEFIX" -type f -print0)
    fi
    ;;
  *) log "casefix: 跳过（当前文件系统大小写不敏感，无需还原）" ;;
esac

# ---------------------------------------------------------------- defconfig 档位
DEF="$ROOT/defconfig/sm8150-perf_defconfig.$PROFILE"
[[ -f "$DEF" ]] || die "未知档位 PROFILE=$PROFILE（可用: stock / clean / custom），缺 $DEF"
cp "$DEF" "$K/arch/arm64/configs/vendor/sm8150-perf_defconfig"
log "应用 defconfig 档位: $PROFILE ($(wc -l < "$DEF") 行)"

# ---------------------------------------------------------------- 工具链探测
CLANG_BIN="$TC/clang/bin"
CLANG_LIB="$TC/clang/lib64"
[[ -x "$CLANG_BIN/clang" ]] || die "缺少 $CLANG_BIN/clang"

if [[ -x "$TC/build-tools/bin/make" ]]; then
  BT_BIN="$TC/build-tools/bin"                 # 系统 host 工具回退
elif [[ -x "$TC/build-tools/linux-x86/bin/make" ]]; then
  BT_BIN="$TC/build-tools/linux-x86/bin"       # AOSP build-tools
else
  die "找不到 make（$TC/build-tools）"
fi
MAKE="$BT_BIN/make"
LEX="${LEX:-$BT_BIN/flex}"; YACC="${YACC:-$BT_BIN/bison}"; M4="${M4:-$BT_BIN/m4}"

GCC64="$TC/gcc64/bin/aarch64-linux-android-"
if [[ -x "$TC/gcc32/bin/arm-linux-androidkernel-gcc" ]]; then
  GCC32="$TC/gcc32/bin/arm-linux-androidkernel-"
else
  GCC32="$TC/gcc32/bin/arm-linux-androideabi-"
fi

# tools-lineage/linux-x86/bin 内含 cpio（CONFIG_IKHEADERS 的 gen_kheaders.sh 依赖）；
# 在线模式该目录为空，由 GitHub Actions 的 apt install cpio 提供
export PATH="$CLANG_BIN:$BT_BIN:$TC/tools-lineage/linux-x86/bin:$TC/gcc64/bin:$TC/gcc32/bin:$PATH"
command -v cpio >/dev/null || die "缺少 cpio（CONFIG_IKHEADERS 的 gen_kheaders.sh 需要）。\
本地模式请确认 prebuilts/tools-lineage/linux-x86/bin/cpio 存在；GitHub Actions 请 apt install cpio"
EXTRA_LIB=""
[[ -d "$TC/tools-lineage/linux-x86/lib" ]] && EXTRA_LIB=":$TC/tools-lineage/linux-x86/lib"
export LD_LIBRARY_PATH="$CLANG_LIB$EXTRA_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
[[ -d "$TC/tools-lineage/common/perl-base" ]] && export PERL5LIB="$TC/tools-lineage/common/perl-base"
[[ -d "$TC/build-tools/common/bison" ]] && export BISON_PKGDATADIR="$TC/build-tools/common/bison"

COMMON=(
  -j"$JOBS"
  CFLAGS_MODULE="-fno-pic"
  CPATH="/usr/include:/usr/include/x86_64-linux-gnu"
  HOSTCFLAGS="-fuse-ld=lld"
  HOSTLDFLAGS="-L/usr/lib/x86_64-linux-gnu -L/usr/lib64 -fuse-ld=lld"
  "HOSTCC=$CLANG_BIN/clang"
  "HOSTCXX=$CLANG_BIN/clang++"
  "LEX=$LEX" "YACC=$YACC" "M4=$M4"
  -C "$K" "O=$OBJ"
  ARCH=arm64
  SUBARCH=arm64
  "CROSS_COMPILE=$GCC64"
  "CROSS_COMPILE_ARM32=$GCC32"
  "CROSS_COMPILE_COMPAT=$GCC32"
  CLANG_TRIPLE=aarch64-linux-gnu-
  "CC= clang"
)

mkdir -p "$OBJ"
run_stage() {
  local name="$1" target="$2"
  log "make $target  (档位 $PROFILE, -j$JOBS)"
  "$MAKE" "${COMMON[@]}" "$target" 2>&1 | tee -a "$LOG"
}

case "$STAGE" in
  defconfig) run_stage defconfig vendor/sm8150-perf_defconfig ;;
  dtbs)      run_stage dtbs dtbs ;;
  image)     run_stage image Image-dtb ;;
  all)
    run_stage defconfig vendor/sm8150-perf_defconfig
    run_stage dtbs dtbs
    run_stage image Image-dtb
    ;;
  *) die "用法: $0 {defconfig|dtbs|image|all} [stock|clean|custom]" ;;
esac

IMG="$OBJ/arch/arm64/boot/Image-dtb"
if [[ -f "$IMG" ]]; then
  log "产物: $IMG ($(stat -c%s "$IMG") B)  sha256=$(sha256sum "$IMG" | cut -c1-16)…"
fi
log "阶段 $STAGE 完成"
