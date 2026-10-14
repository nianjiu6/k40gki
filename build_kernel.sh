#!/bin/bash

# Exit on any error
set -eE
set -o pipefail
trap 'rc=$?; echo "[!] Build failed at line $LINENO (exit $rc): $BASH_COMMAND" >&2; exit "$rc"' ERR

cd "$(dirname "$(realpath "$0")")"

# ==========================================
# Argument Parsing
# ==========================================
if [ -z "$1" ]; then
    echo "[!] Error: No device specified."
    echo "Usage: $0 <device_name> [ksu] [miui|aosp]"
    echo "Example: $0 lmi"
    echo "         $0 lmi ksu"
    echo "         $0 lmi ksu miui"
    echo "         $0 lmi aosp"
    exit 1
fi

DEVICE_NAME="$1"
DEFCONFIG="${DEVICE_NAME}_defconfig"
DEFCONFIG_PATH="arch/arm64/configs/${DEFCONFIG}"

if [ ! -f "$DEFCONFIG_PATH" ]; then
    echo "[!] Error: Defconfig not found at $DEFCONFIG_PATH"
    echo "[!] Please verify the device name and try again."
    exit 1
fi

ENABLE_KSU=0
TARGET_OS="both"

shift
# Parse remaining arguments loosely
for arg in "$@"; do
    case "$arg" in
        ksu) ENABLE_KSU=1 ;;
        miui) TARGET_OS="miui" ;;
        aosp) TARGET_OS="aosp" ;;
    esac
done

# ==========================================
# Configuration & Environment
# ==========================================
KERNEL_DIR="$(pwd)"
TOOLCHAIN_BIN="${TOOLCHAIN_BIN:-$HOME/zyc-clang/bin}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
RESUKISU_REF="239e1e8871b8fcd51a6e5b3002e0ba522fdd99fb"
RESUKISU_UAPI5_REF="8770c7e324a22895703c4916b8a16520e0b81c79"
BBG_REF="a54e0dc6cf0aff4dd87fec49644a02d2eb612905"
ANYKERNEL_REF="332c0e860d3a27ad7c746ba813b9fb09afcc0684"

export PATH="${TOOLCHAIN_BIN}:${PATH}"
export ARCH="arm64"
export SUBARCH="arm64"

# ccache Setup
export CCACHE_DIR="$HOME/.cache/ccache_mikernel"
export CCACHE_EXEC=$(command -v ccache)

if [ -z "$CCACHE_EXEC" ]; then
    echo "[!] ccache not found! Please install ccache first."
    exit 1
fi

export USE_CCACHE=1
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"

echo "[*] Checking Clang version..."
clang --version || { echo "[!] Clang not found at ${TOOLCHAIN_BIN}. Please check the path."; exit 1; }

echo "[*] Setting up ccache in $CCACHE_DIR..."
mkdir -p "$CCACHE_DIR"
ccache --max-size=4G

# ==========================================
# Kernel Version & Build Banner Pinning
# ==========================================
# Match the stock HyperOS banner on alioth:
#   4.19.157-perf-g92c089fc2d37 #1 SMP PREEMPT Wed Oct 29 11:41:46 UTC 2025
# SUBLEVEL lives in the top Makefile, "-perf" comes from CONFIG_LOCALVERSION,
# and scripts/setlocalversion returns .scmversion verbatim when it exists.
EXPECTED_KERNEL_RELEASE="4.19.157-perf-g92c089fc2d37"
EXPECTED_BUILD_TIMESTAMP="Wed Oct 29 11:41:46 UTC 2025"

export KBUILD_BUILD_TIMESTAMP="${EXPECTED_BUILD_TIMESTAMP}"
export KBUILD_BUILD_VERSION=1
printf '%s\n' '-g92c089fc2d37' > .scmversion
# setlocalversion prepends the contents of every localversion* file to
# CONFIG_LOCALVERSION. This tree ships localversion-cip (-cip132) and
# localversion-st (-st16), which would turn the release into
# 4.19.157-cip132-st16-perf-g92c089fc2d37.
rm -f localversion*

echo "[*] Pinned kernel release: ${EXPECTED_KERNEL_RELEASE}"
echo "[*] Pinned build time: ${EXPECTED_BUILD_TIMESTAMP}"

# ==========================================
# KernelSU Setup
# ==========================================
if [ "$ENABLE_KSU" -eq 1 ]; then
    echo "==========================================="
    echo " [*] Initializing KernelSU (ReSukiSU) Setup"
    echo "==========================================="
    echo "[*] Setting up ReSukiSU v4.2.0-rc3 (${RESUKISU_REF})..."
    # Kbuild derives the manager version code from the complete commit history.
    if [ ! -e KernelSU ]; then
        git clone https://github.com/Baka-SU/BakaSU.git KernelSU
    fi
    git -C KernelSU cat-file -e "${RESUKISU_REF}^{commit}" || git -C KernelSU fetch origin "${RESUKISU_REF}"
    git -C KernelSU checkout --detach "${RESUKISU_REF}"
    test "$(git -C KernelSU rev-parse HEAD)" = "${RESUKISU_REF}"
    echo "[*] Backporting UAPI 5 kernel services protocol (${RESUKISU_UAPI5_REF})..."
    git -C KernelSU cat-file -e "${RESUKISU_UAPI5_REF}^{commit}" || git -C KernelSU fetch origin "${RESUKISU_UAPI5_REF}"
    git -C KernelSU show --format= --binary "${RESUKISU_UAPI5_REF}" -- \
        kernel/supercall/dispatch.c uapi/supercall.h > "${KERNEL_DIR}/.resukisu-uapi5.patch"
    if git -C KernelSU apply --reverse --check "${KERNEL_DIR}/.resukisu-uapi5.patch" 2>/dev/null; then
        echo "[*] UAPI 5 services backport already applied."
    else
        git -C KernelSU apply --check "${KERNEL_DIR}/.resukisu-uapi5.patch"
        git -C KernelSU apply "${KERNEL_DIR}/.resukisu-uapi5.patch"
    fi
    grep -qF 'KERNEL_SU_UAPI_VERSION = 5;' KernelSU/uapi/supercall.h
    grep -qF 'case EVENT_SERVICES:' KernelSU/kernel/supercall/dispatch.c
    grep -qF 'services_started = true;' KernelSU/kernel/supercall/dispatch.c
    test "$(git -C KernelSU rev-parse HEAD)" = "${RESUKISU_REF}"
    ln -sfn ../KernelSU/kernel drivers/kernelsu
    if ! grep -qF 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile; then
        printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
    fi
    if ! grep -qF 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig; then
        sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig
    fi
    # ReSukiSU Kconfig choice defaults to KSU_TRACEPOINT_HOOK (GKI 2.0 / 5.10+ only).
    # This tree is Linux 4.19 non-GKI and already has SuSFS v2.2.0 inline hooks.
    # Leaving the default causes: \"TP hooks are incompatible with Non-GKI\" (make exit 2).
    if [ -f KernelSU/kernel/Kconfig ]; then
        sed -i 's/default KSU_TRACEPOINT_HOOK/default KSU_SUSFS/' KernelSU/kernel/Kconfig
        echo "[+] ReSukiSU default hook switched to KSU_SUSFS for non-GKI 4.19"
    fi
    echo "[*] Applying 4.19 manager-launch runtime patches..."
    python3 scripts/patch_resukisu_419.py
    python3 -m unittest discover -s scripts/tests -p test_patch_resukisu_419.py -v
    echo "[+] KernelSU setup finished."
fi

# ==========================================
# Baseband-guard Setup
# ==========================================
echo "==========================================="
echo " [*] Initializing Baseband-guard Setup"
echo "==========================================="
echo "[*] Setting up Baseband-guard (${BBG_REF})..."
if [ ! -e Baseband-guard ]; then
    git clone https://github.com/vc-teahouse/Baseband-guard.git Baseband-guard
fi
git -C Baseband-guard cat-file -e "${BBG_REF}^{commit}" || git -C Baseband-guard fetch origin "${BBG_REF}"
git -C Baseband-guard checkout --detach "${BBG_REF}"
bash Baseband-guard/setup.sh "${BBG_REF}"
test "$(git -C Baseband-guard rev-parse HEAD)" = "${BBG_REF}"

echo "[*] Patching security/Kconfig for baseband_guard..."
sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' security/Kconfig
echo "[+] Baseband-guard setup finished."
echo "==========================================="

# ==========================================
# AnyKernel3 Setup
# ==========================================
echo "==========================================="
echo " [*] Initializing AnyKernel3 Workspace"
echo "==========================================="
rm -rf anykernel
echo "[*] Cloning AnyKernel3..."
git init anykernel
git -C anykernel remote add origin https://github.com/AstideLabs/AnyKernel3.git
git -C anykernel fetch --depth=1 origin "${ANYKERNEL_REF}"
git -C anykernel checkout --detach FETCH_HEAD
test "$(git -C anykernel rev-parse HEAD)" = "${ANYKERNEL_REF}"
echo "[+] AnyKernel3 checked out at ${ANYKERNEL_REF}."
echo "==========================================="

# ==========================================
# Modular Build Function
# ==========================================
build_target() {
    local OS_TYPE=$1
    echo "==========================================="
    echo " Starting Kernel Compilation for ${DEVICE_NAME} (Target: $OS_TYPE)"
    echo "==========================================="
    
    local OUT_DIR="${KERNEL_DIR}/out_${OS_TYPE}"
    
    local MAKE_OPTS=(
        -j"${BUILD_JOBS}"
        O="${OUT_DIR}"
        ARCH="${ARCH}"
        SUBARCH="${SUBARCH}"
        LLVM=1
        LLVM_IAS=1
        CC="ccache clang"
        HOSTCC="ccache clang"
        PYTHON=python3
        CROSS_COMPILE="${CROSS_COMPILE}"
        CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}"
    )

    echo "[*] Cleaning ${OUT_DIR}..."
    rm -rf "${OUT_DIR}"
    mkdir -p "${OUT_DIR}"

    local DTS_SOURCE="arch/arm64/boot/dts/vendor/qcom"
    local DTS_BACKUP=".dts.bak.${OS_TYPE}"

    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Applying MIUI DTS patches..."
        cp -a "${DTS_SOURCE}" "${DTS_BACKUP}"
        
        # Apply MIUI specific sed patches to dts
        sed -i 's/<154>/<1537>/g' ${DTS_SOURCE}/dsi-panel-j1s* || true
        sed -i 's/<154>/<1537>/g' ${DTS_SOURCE}/dsi-panel-j2* || true
        sed -i 's/<155>/<1544>/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true
        sed -i 's/<155>/<1545>/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/<155>/<1546>/g' ${DTS_SOURCE}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<155>/<1546>/g' ${DTS_SOURCE}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<71>/<710>/g' ${DTS_SOURCE}/dsi-panel-j1s* || true
        sed -i 's/<71>/<710>/g' ${DTS_SOURCE}/dsi-panel-j2* || true

        sed -i 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g' ${DTS_SOURCE}/dsi-panel* || true

        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-36-02-0c-dsc-video.dtsi || true
        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-37-02-0a-dsc-video.dtsi || true
        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-37-02-0b-dsc-video.dtsi || true
        sed -i 's/144 120 90 60/144 120 90 60 50 48 30/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true

        sed -i 's/\/\/39 00 00 00 00 00 03 51 03 FF/39 00 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 03 51 0D FF/39 00 00 00 00 00 03 51 0D FF/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 01 00 03 51 03 FF/39 01 00 00 01 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 11 00 03 51 03 FF/39 01 00 00 11 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi || true
    fi

    echo "[*] Making defconfig: ${DEFCONFIG}..."
    make "${MAKE_OPTS[@]}" "${DEFCONFIG}"

    # ----------------------------------------------------
    # Configuration tweaks
    # ----------------------------------------------------
    
    # 1. Baseband-guard configuration (Always applied)
    echo "[*] Injecting Baseband-guard configuration..."
    scripts/config --file "${OUT_DIR}/.config" -e BBG

    # 2. KernelSU configurations
    # Force SuSFS inline hook. scripts/config -e KSU_SUSFS does not disable the
    # other choice member, so TRACEPOINT can remain y and olddefconfig may keep it.
    if [ "$ENABLE_KSU" -eq 1 ]; then
        echo "[*] Injecting KernelSU & SUSFS configurations (non-GKI 4.19)..."
        scripts/config --file "${OUT_DIR}/.config" \
            -e KSU \
            -e KALLSYMS \
            -e KALLSYMS_ALL \
            -e THREAD_INFO_IN_TASK \
            -d KSU_TRACEPOINT_HOOK \
            -d KSU_MANUAL_HOOK \
            -e KSU_SUSFS \
            -d CC_WERROR \
            -d CFI_CLANG \
            -d CFI_PERMISSIVE \
            -d LTO_CLANG \
            -e LTO_NONE \
            -d SHADOW_CALL_STACK
    fi

    # 3. MIUI configurations
    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Injecting MIUI specific configurations..."
        scripts/config --file "${OUT_DIR}/.config" \
            --set-str STATIC_USERMODEHELPER_PATH /system/bin/micd \
            -e PERF_CRITICAL_RT_TASK \
            -e SF_BINDER \
            -e OVERLAY_FS \
            -e MIGT \
            -e MIGT_ENERGY_MODEL \
            -e MIHW \
            -e PACKAGE_RUNTIME_INFO \
            -e BINDER_OPT \
            -e KPERFEVENTS \
            -e MILLET \
            -e PERF_HUMANTASK \
            -d LTO_CLANG \
            -e LTO_NONE \
            -d SHADOW_CALL_STACK \
            -e XIAOMI_MIUI \
            -d MI_MEMORY_SYSFS \
            -e TASK_DELAY_ACCT \
            -e MIUI_ZRAM_MEMORY_TRACKING \
            -e PERF_HELPER \
            -e BOOTUP_RECLAIM \
            -e MI_RECLAIM \
            -e RTMM \
            -d REKERNEL \
            -d REKERNEL_NETWORK
    fi

    # We always need to re-evaluate dependencies because BBG is injected unconditionally
    echo "[*] Updating config (make olddefconfig)..."
    make "${MAKE_OPTS[@]}" olddefconfig

    if [ "$ENABLE_KSU" -eq 1 ]; then
        # olddefconfig may restore the choice default; re-apply and verify.
        scripts/config --file "${OUT_DIR}/.config" \
            -e KSU \
            -e KALLSYMS \
            -e KALLSYMS_ALL \
            -e THREAD_INFO_IN_TASK \
            -d KSU_TRACEPOINT_HOOK \
            -d KSU_MANUAL_HOOK \
            -e KSU_SUSFS \
            -d CC_WERROR \
            -d CFI_CLANG \
            -d CFI_PERMISSIVE \
            -d LTO_CLANG \
            -e LTO_NONE \
            -d SHADOW_CALL_STACK
        make "${MAKE_OPTS[@]}" olddefconfig

        echo "[*] KernelSU-related config:"
        grep -E '^CONFIG_KSU|^# CONFIG_KSU|^CONFIG_THREAD_INFO_IN_TASK|^CONFIG_CC_WERROR|^CONFIG_CFI|^# CONFIG_CFI|^CONFIG_LTO|^# CONFIG_LTO' "${OUT_DIR}/.config" || true

        if grep -q '^CONFIG_KSU_TRACEPOINT_HOOK=y' "${OUT_DIR}/.config"; then
            echo "[!] Error: CONFIG_KSU_TRACEPOINT_HOOK=y. 4.19 non-GKI cannot use Tracepoint hooks."
            exit 1
        fi
        if grep -q '^CONFIG_CFI_CLANG=y' "${OUT_DIR}/.config"; then
            echo "[!] Error: CONFIG_CFI_CLANG=y. Manager ioctl/anon inode will panic on 4.19."
            exit 1
        fi
        if grep -q '^CONFIG_LTO_CLANG=y' "${OUT_DIR}/.config"; then
            echo "[!] Error: CONFIG_LTO_CLANG=y. CFI depends on LTO; keep both off for KSU."
            exit 1
        fi
        if ! grep -q '^CONFIG_KSU=y' "${OUT_DIR}/.config"; then
            echo "[!] Error: CONFIG_KSU is not enabled."
            exit 1
        fi
        if ! grep -q '^CONFIG_KSU_SUSFS=y' "${OUT_DIR}/.config"; then
            echo "[!] Error: CONFIG_KSU_SUSFS is not enabled. SuSFS inline hook is required."
            exit 1
        fi
    fi

    # ----------------------------------------------------
    # Compilation
    # ----------------------------------------------------
    echo "[*] Building kernel..."
    make "${MAKE_OPTS[@]}"

    # ----------------------------------------------------
    # Verify the pinned version banner
    # ----------------------------------------------------
    local RELEASE_FILE="${OUT_DIR}/include/config/kernel.release"
    local COMPILE_H="${OUT_DIR}/include/generated/compile.h"

    if [ ! -f "$RELEASE_FILE" ] || [ "$(cat "$RELEASE_FILE")" != "$EXPECTED_KERNEL_RELEASE" ]; then
        echo "[!] Error: kernel release is '$(cat "$RELEASE_FILE" 2>/dev/null)', expected '${EXPECTED_KERNEL_RELEASE}'."
        exit 1
    fi
    if [ ! -f "$COMPILE_H" ] ||
       ! grep -qF "#1 SMP PREEMPT ${EXPECTED_BUILD_TIMESTAMP}" "$COMPILE_H"; then
        echo "[!] Error: UTS_VERSION does not match '#1 SMP PREEMPT ${EXPECTED_BUILD_TIMESTAMP}'."
        exit 1
    fi
    echo "[+] Version banner verified: $(cat "$RELEASE_FILE") @ ${EXPECTED_BUILD_TIMESTAMP}"

    # Restore DTS backup for MIUI
    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Restoring DTS backups..."
        rm -rf "${DTS_SOURCE}"
        mv "${DTS_BACKUP}" "${DTS_SOURCE}"
    fi

    echo "==========================================="
    if [ -f "${OUT_DIR}/arch/arm64/boot/Image" ]; then
        echo "[+] $OS_TYPE Build Successful!"
        echo "[+] Kernel Image path: ${OUT_DIR}/arch/arm64/boot/Image"
        
        echo "[*] Preparing device-checked AnyKernel3 ($OS_TYPE), preserving stock dtbo..."
        python3 scripts/package_anykernel.py anykernel "${OUT_DIR}" "${DEVICE_NAME}" "${OS_TYPE}"
        local RESUKISU_ACTUAL_REF="disabled"
        local RESUKISU_UAPI_VERSION="disabled"
        local RESUKISU_SERVICES_REF="disabled"
        if [ "$ENABLE_KSU" -eq 1 ]; then
            RESUKISU_ACTUAL_REF=$(git -C KernelSU rev-parse HEAD)
            RESUKISU_UAPI_VERSION=$(awk '/^static const __u32 KERNEL_SU_UAPI_VERSION = / {gsub(/;/, "", $NF); print $NF}' KernelSU/uapi/supercall.h)
            RESUKISU_SERVICES_REF="$RESUKISU_UAPI5_REF"
            test "$RESUKISU_ACTUAL_REF" = "$RESUKISU_REF"
            test "$RESUKISU_UAPI_VERSION" = 5
        fi
        {
            printf 'device=%s\nos=%s\n' "${DEVICE_NAME}" "${OS_TYPE}"
            printf 'kernel_commit=%s\n' "$(git rev-parse HEAD)"
            printf 'kernel_release=%s\n' "$(cat "$RELEASE_FILE")"
            printf 'resukisu_commit=%s\n' "$RESUKISU_ACTUAL_REF"
            printf 'resukisu_uapi=%s\nresukisu_services_backport=%s\n' "$RESUKISU_UAPI_VERSION" "$RESUKISU_SERVICES_REF"
            printf 'baseband_guard_commit=%s\nanykernel_commit=%s\n' "$BBG_REF" "$ANYKERNEL_REF"
            printf 'dtbo=preserved\n'
        } > anykernel/build-info.txt
        
        # 硫3定 ZIP 文件名
        local KSU_ZIP_STR="NoKernelSU"
        if [ "$ENABLE_KSU" -eq 1 ]; then
            KSU_ZIP_STR="ReSukiSU-SuSFS"
        fi
        local GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD 2>/dev/null || echo "unknown")
        local OS_UPPER=$(echo "$OS_TYPE" | tr '[:lower:]' '[:upper:]')
        local ZIP_FILENAME="APTKernel_${OS_UPPER}_${DEVICE_NAME}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip"
        
        echo "[*] Zipping $ZIP_FILENAME ..."
        pushd anykernel > /dev/null
        zip -r9 "$ZIP_FILENAME" META-INF tools anykernel.sh Image dtb build-info.txt > /dev/null
        mv "$ZIP_FILENAME" ../
        popd > /dev/null
        unzip -t "$ZIP_FILENAME"
        sha256sum "$ZIP_FILENAME" > "${ZIP_FILENAME}.sha256"
        
        echo "[+] $OS_TYPE kernel binaries successfully packed into: $ZIP_FILENAME"
    else
        echo "[-] $OS_TYPE Build Failed. Kernel Image not found."
        exit 1
    fi
}

# ==========================================
# Execute builds based on target OS
# ==========================================
if [ "$TARGET_OS" == "aosp" ] || [ "$TARGET_OS" == "both" ]; then
    build_target "aosp"
fi

if [ "$TARGET_OS" == "miui" ] || [ "$TARGET_OS" == "both" ]; then
    build_target "miui"
fi

echo "==========================================="
echo "[*] ccache stats:"
ccache -s
echo "[+] All requested builds completed!"
