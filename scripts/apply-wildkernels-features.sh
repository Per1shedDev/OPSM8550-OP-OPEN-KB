#!/usr/bin/env bash
# Port the WildKernels feature set to the crDroid OnePlus Open (SM8550) tree.
# Upstream patch sources are pinned to immutable commits; every patch is checked
# before application, and an incompatible patch stops the build instead of
# silently producing a partial feature set.
set -euo pipefail

KERNEL_ROOT="${1:-$PWD}"
MODE="${2:-apply}"
PATCHES_COMMIT="b61ceb600da12ef1093597d8a4dfc15d0297b3c1"
WILDKERNELS_GKI_COMMIT="30216b4dbb62f496bd206eb34fdafd13da08ed8d"
DROIDSPACES_PATCH_COMMIT="023013a9ea07cd5a22d0e3bd57062c597c87ee03"
BBG_COMMIT="028ff7fd509e2104596da7cc1ef8e6ce2a0c9082"
PATCH_CACHE="${GITHUB_WORKSPACE:-$KERNEL_ROOT}/.wildkernels-patches"
DEFCONFIG="$KERNEL_ROOT/arch/arm64/configs/gki_defconfig"
PROOF="$KERNEL_ROOT/wildkernels-features-proof.txt"

die() { echo "::error::$*" >&2; exit 1; }
note() { echo "[WildKernels] $*"; }

[[ -d "$KERNEL_ROOT" ]] || die "Kernel source directory not found: $KERNEL_ROOT"
[[ -f "$DEFCONFIG" ]] || die "Expected GKI defconfig not found: $DEFCONFIG"
mkdir -p "$PATCH_CACHE"

fetch_patch() {
  local path="$1"
  local out="$PATCH_CACHE/${path//\//__}"
  if [[ ! -s "$out" ]]; then
    note "Downloading $path" >&2
    curl --fail --location --silent --show-error --retry 3 \
      "https://raw.githubusercontent.com/WildKernels/kernel_patches/$PATCHES_COMMIT/$path" -o "$out"
  fi
  [[ -s "$out" ]] || die "Missing upstream patch: $path"
  printf '%s\n' "$out"
}

apply_patch_file() {
  local patch_file="$1"
  local label="$2"
  if patch --dry-run --batch --forward -p1 < "$patch_file" >/dev/null 2>&1; then
    patch --batch --forward -p1 < "$patch_file"
    note "Applied $label"
  elif patch --dry-run --batch --reverse -p1 < "$patch_file" >/dev/null 2>&1; then
    note "Already present: $label"
  else
    die "Patch is not compatible with this crDroid kernel tree: $label"
  fi
}

apply_upstream_patch() {
  local path="$1"
  apply_patch_file "$(fetch_patch "$path")" "$path"
}

apply_droidspaces_sysvipc_patch() {
  local patch_file="$PATCH_CACHE/sysvipc-kabi-6-7-8.patch"
  if [[ ! -s "$patch_file" ]]; then
    note "Downloading Droidspaces SYSVIPC KABI patch (slots 6-8)" >&2
    curl --fail --location --silent --show-error --retry 3 \
      "https://raw.githubusercontent.com/ravindu644/Droidspaces-OSS/$DROIDSPACES_PATCH_COMMIT/Documentation/resources/kernel-patches/GKI/below-kernel-6.12/001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch" \
      -o "$patch_file"
  fi
  apply_patch_file "$patch_file" "Droidspaces SYSVIPC KABI patch (slots 6-8)"
  grep -Fq "ANDROID_KABI_USE(6, struct sysv_sem sysvsem);" "$KERNEL_ROOT/include/linux/sched.h" || die "SYSVIPC semaphore field was not moved into KABI slot 6"
  grep -Fq "_ANDROID_KABI_REPLACE(ANDROID_KABI_RESERVE(7); ANDROID_KABI_RESERVE(8), struct sysv_shm sysvshm);" "$KERNEL_ROOT/include/linux/sched.h" || die "SYSVIPC shared-memory field was not moved into KABI slots 7-8"
  echo "sysvipc_kabi_layout=slot1:user_dumpable;slots2-5:reserved;sysvsem:slot6;sysvshm:slots7-8" >> "$PROOF"
}

apply_android14_5_15_bbrv3_patch() {
  local patch_file="$PATCH_CACHE/bbrv3-android14-5.15.patch"
  if [[ ! -s "$patch_file" ]]; then
    note "Downloading WildKernels Android 14 / 5.15 BBRv3 patch" >&2
    curl --fail --location --silent --show-error --retry 3 \
      "https://raw.githubusercontent.com/WildKernels/GKI_KernelSU_SUSFS/$WILDKERNELS_GKI_COMMIT/.github/actions/bbrv3/patches/0001-net-tcp-backport-BBRv3-to-android14-5.15.patch" \
      -o "$patch_file"
  fi
  # crDroid's tcp_sk_init() already declares res, cpu, and cnt. The
  # upstream Android 14 patch assumes the leaner GKI declaration "int cnt;"
  # and replaces it, which makes the otherwise-compatible patch reject.
  # Retarget only that declaration hunk; preserve all BBRv3 implementation
  # hunks and keep the patch check strict.
  local adapted_patch="$PATCH_CACHE/bbrv3-android14-5.15-crdroid.patch"
  sed \
    -e 's/^-\tint cnt;$/-\tint res, cpu, cnt;/' \
    -e 's/^+\tint cnt;$/+\tint res, cpu, cnt;/' \
    "$patch_file" > "$adapted_patch"
  grep -Fq -- '-	int res, cpu, cnt;' "$adapted_patch" || die "Could not adapt BBRv3 tcp_sk_init declaration for crDroid"
  grep -Fq -- '+	struct tcp_plb_net_context *ctx, *init_ctx;' "$adapted_patch" || die "BBRv3 crDroid adaptation lost PLB context declarations"
  apply_patch_file "$adapted_patch" "WildKernels BBRv3 android14-5.15 (crDroid declaration adaptation)"
}
set_defconfig() {
  local key="$1" value="$2"
  if grep -q "^$key=" "$DEFCONFIG"; then
    sed -i "s|^$key=.*|$key=$value|" "$DEFCONFIG"
  elif grep -q "^# $key is not set$" "$DEFCONFIG"; then
    sed -i "s|^# $key is not set$|$key=$value|" "$DEFCONFIG"
  else
    printf '%s=%s\n' "$key" "$value" >> "$DEFCONFIG"
  fi
}

set_configs() {
  local pair
  for pair in "$@"; do
    set_defconfig "${pair%%=*}" "${pair#*=}"
  done
}

setup_bbg() {
  local bbg_dir="$KERNEL_ROOT/Baseband-guard"
  if [[ ! -d "$bbg_dir/.git" ]]; then
    rm -rf "$bbg_dir"
    git init -q "$bbg_dir"
    git -C "$bbg_dir" remote add origin https://github.com/vc-teahouse/Baseband-guard.git
  fi
  git -C "$bbg_dir" fetch --depth=1 origin "$BBG_COMMIT"
  git -C "$bbg_dir" checkout -q --detach FETCH_HEAD
  [[ "$(git -C "$bbg_dir" rev-parse HEAD)" == "$BBG_COMMIT" ]] || die "BBG checkout did not match pinned commit"
  # The upstream setup script is idempotent and handles both modern GKI LSM
  # wiring and older SELinux compatibility. Passing the commit pins its source.
  (cd "$KERNEL_ROOT" && sh "$bbg_dir/setup.sh" "$BBG_COMMIT")
  [[ -L "$KERNEL_ROOT/security/baseband-guard" ]] || die "BBG security symlink was not created"
  grep -q 'baseband_guard' "$KERNEL_ROOT/security/Makefile" || die "BBG Kbuild entry missing"
  grep -q 'security/baseband-guard/Kconfig' "$KERNEL_ROOT/security/Kconfig" || die "BBG Kconfig entry missing"
  # Match WildKernels' LSM registration: retain the kernel's existing LSM order
  # and append baseband_guard to the SELinux default.
  sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' "$KERNEL_ROOT/security/Kconfig"
  grep -Eq '^[[:space:]]*default[[:space:]]+"[^"]*baseband_guard' "$KERNEL_ROOT/security/Kconfig" || die "BBG is not registered in the active LSM default"
  set_defconfig CONFIG_BBG y
}

apply_optimisations() {
  # These are the common optimisation patches used by WildKernels for 5.15.
  local paths=(
    common/optimized_mem_operations.patch
    common/file_struct_8bytes_align.patch
    common/reduce_cache_pressure.patch
    common/mem_opt_prefetch.patch
  )
  local path
  for path in "${paths[@]}"; do apply_upstream_patch "$path"; done

  # WildKernels adapts the upstream memcmp and clear_page assembly labels for
  # pre-5.16 kernels. Keep those compatibility edits local to the patch stream.
  local p tmp
  p="$(fetch_patch common/optimise_memcmp.patch)"
  tmp="$PATCH_CACHE/optimise_memcmp-5.15.patch"
  sed -e 's/SYM_FUNC_START(__pi_memcmp)/SYM_FUNC_START_WEAK_PI(memcmp)/' \
      -e 's/SYM_FUNC_END(__pi_memcmp)/SYM_FUNC_END_PI(memcmp)/' \
      -e 's/SYM_FUNC_ALIAS_WEAK(memcmp, __pi_memcmp)/EXPORT_SYMBOL_NOKASAN(memcmp)/' "$p" > "$tmp"
  apply_patch_file "$tmp" "common/optimise_memcmp.patch (5.15 adaptation)"

  for path in \
    common/minimise_wakeup_time.patch \
    common/int_sqrt.patch \
    common/reduce_gc_thread_sleep_time.patch \
    common/add_timeout_wakelocks_globally.patch \
    common/f2fs_reduce_congestion.patch \
    common/reduce_freeze_timeout.patch; do
    apply_upstream_patch "$path"
  done

  p="$(fetch_patch common/clear_page_16bytes_align.patch)"
  tmp="$PATCH_CACHE/clear_page_16bytes_align-5.15.patch"
  sed -e 's/SYM_FUNC_START_PI(clear_page)/SYM_FUNC_START_PI(__pi_clear_page)/' "$p" > "$tmp"
  apply_patch_file "$tmp" "common/clear_page_16bytes_align.patch (5.15 adaptation)"

  for path in \
    common/add_limitation_scaling_min_freq.patch \
    common/re_write_limitation_scaling_min_freq.patch \
    common/adjust_cpu_scan_order.patch \
    common/avoid_extra_s2idle_wake_attempts.patch \
    common/disable_cache_hot_buddy.patch \
    common/f2fs_enlarge_min_fsync_blocks.patch \
    common/increase_ext4_default_commit_age.patch \
    common/increase_sk_mem_packets.patch \
    common/reduce_pci_pme_wakeups.patch \
    common/silence_irq_cpu_logspam.patch \
    common/silence_system_logspam.patch \
    common/use_unlikely_wrap_cpufreq.patch; do
    apply_upstream_patch "$path"
  done
}

apply_features() {
  cd "$KERNEL_ROOT"
  : > "$PROOF"
  {
    echo "profile=sm8550-oneplus-open-crdroid"
    echo "kernel_source=crDroid Android 17"
    echo "kernel_family=android14-5.15"
    echo "patches_repo_commit=$PATCHES_COMMIT"
    echo "baseband_guard_commit=$BBG_COMMIT"
  } >> "$PROOF"

  # Ptrace leak fix is specifically required by WildKernels on kernels < 5.16.
  apply_upstream_patch gki_ptrace.patch

  # Use the dedicated WildKernels Android 14 / 5.15 BBRv3 patch, not
  # the Android 13 / 5.15 variant from kernel_patches.
  apply_android14_5_15_bbrv3_patch

  # Droidspaces' Android 14 / 5.15-compatible SYSVIPC KABI patch uses slots
  # 6-8, preserving crDroid's existing user_dumpable slot 1 and reserves 2-5.
  apply_droidspaces_sysvipc_patch
  apply_upstream_patch common/droidspaces/0001-Return-ghost-task-if-task-is-null-and-is-requested-b.patch

  # OnePlus module interception/overlay support. The OP-OPEN Android 17
  # profile uses the Android 14 / 5.15 KMI; this is the available 5.15
  # backport variant and must match the downstream source before proceeding.
  apply_upstream_patch oneplus/module_overlay/0001-module-Add-module-intercept-and-overlay-mechanism-android13-5.15.patch
  if [[ -f "$KERNEL_ROOT/kernel/module_overlay/convert_overlay.sh" ]]; then
    chmod +x "$KERNEL_ROOT/kernel/module_overlay/convert_overlay.sh"
  elif [[ -f "$KERNEL_ROOT/kernel/module/module_overlay/convert_overlay.sh" ]]; then
    chmod +x "$KERNEL_ROOT/kernel/module/module_overlay/convert_overlay.sh"
  else
    die "Module overlay patch applied but convert_overlay.sh was not created"
  fi

  # NTSync has a 5.15 compatibility backport (the only 5.15 variant published
  # by WildKernels); apply only if its hunks match the crDroid Android 17
  # Android 14 / 5.15 KMI tree.
  apply_upstream_patch common/ntsync/ntsync_compat_android13-5.15.patch
  apply_upstream_patch common/ntsync/ntsync_base.patch

  # Unicode path-handling bypass fix for kernels below 5.16.
  apply_upstream_patch common/unicode_bypass_fix_6.1-.patch

  # Baseband Guard is an LSM integration, not merely a Kconfig toggle.
  setup_bbg

  # WildKernels performance/network feature set.
  set_configs \
    CONFIG_TMPFS_XATTR=y \
    CONFIG_TMPFS_POSIX_ACL=y \
    CONFIG_TCP_CONG_ADVANCED=y \
    CONFIG_TCP_CONG_BBR=y \
    CONFIG_TCP_CONG_BBR3=y \
    CONFIG_NET_SCH_FQ=y \
    CONFIG_NET_SCH_FQ_CODEL=y \
    CONFIG_NET_SCH_CAKE=y \
    CONFIG_NET_SCH_PIE=y \
    CONFIG_NET_SCH_FQ_PIE=y \
    CONFIG_IP_NF_TARGET_TTL=y \
    CONFIG_IP6_NF_TARGET_HL=y \
    CONFIG_IP6_NF_MATCH_HL=y \
    CONFIG_BPF_STREAM_PARSER=y \
    CONFIG_IP_SET=y \
    CONFIG_IP_SET_MAX=65534 \
    CONFIG_IP_SET_BITMAP_IP=y \
    CONFIG_IP_SET_BITMAP_IPMAC=y \
    CONFIG_IP_SET_BITMAP_PORT=y \
    CONFIG_IP_SET_HASH_IP=y \
    CONFIG_IP_SET_HASH_IPMARK=y \
    CONFIG_IP_SET_HASH_IPPORT=y \
    CONFIG_IP_SET_HASH_IPPORTIP=y \
    CONFIG_IP_SET_HASH_IPPORTNET=y \
    CONFIG_IP_SET_HASH_IPMAC=y \
    CONFIG_IP_SET_HASH_MAC=y \
    CONFIG_IP_SET_HASH_NETPORTNET=y \
    CONFIG_IP_SET_HASH_NET=y \
    CONFIG_IP_SET_HASH_NETNET=y \
    CONFIG_IP_SET_HASH_NETPORT=y \
    CONFIG_IP_SET_HASH_NETIFACE=y \
    CONFIG_IP_SET_LIST_SET=y \
    CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y \
    CONFIG_NETFILTER_XT_SET=y \
    CONFIG_IP6_NF_NAT=y \
    CONFIG_IP6_NF_TARGET_MASQUERADE=y \
    CONFIG_NTSYNC=y \
    CONFIG_SYSVIPC=y \
    CONFIG_DEVTMPFS=y \
    CONFIG_PID_NS=y \
    CONFIG_POSIX_MQUEUE=y \
    CONFIG_NETFILTER_XT_TARGET_REJECT=y \
    CONFIG_NETFILTER_XT_TARGET_LOG=y \
    CONFIG_NETFILTER_XT_MATCH_RECENT=y \
    CONFIG_USER_NS=y \
    CONFIG_MACVLAN=y \
    CONFIG_LTO_CLANG=y \
    CONFIG_LTO_CLANG_THIN=y \
    CONFIG_LTO_CLANG_FULL=n \
    CONFIG_LTO_CLANG_NONE=n \
    CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y \
    CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE_O3=n \
    CONFIG_OPTIMIZE_INLINING=y \
    CONFIG_FRAME_WARN=0 \
    CONFIG_TRACEPOINTS=y

  # Apply the full WildKernels optimization bundle after the base functional
  # patches, so any source-level conflicts are reported before configuration.
  apply_optimisations

  # The stock WildKernels OP-OPEN profile sets hmbird=false. Do not import
  # HMBIRD/SCX, which is intended for other SoCs and is not enabled on SM8550.
  {
    echo "features=BBR,BBRv3,BBG,CAKE,PIE,ptrace-fix,module-overlay,optimisations,TTL,IP_SET,IPv6_NAT,TMPFS_XATTR,TMPFS_POSIX_ACL,Unicode,Droidspaces,NTSync"
    echo "hmbird=false"
    echo "status=source patches applied; final .config validation follows"
  } >> "$PROOF"
  note "WildKernels source integrations applied for OnePlus Open."
}

verify_config() {
  local config_file="${1:-$KERNEL_ROOT/out/.config}"
  [[ -s "$config_file" ]] || die "Final kernel config not found: $config_file"
  local required=(
    CONFIG_BBG
    CONFIG_TCP_CONG_ADVANCED CONFIG_TCP_CONG_BBR CONFIG_TCP_CONG_BBR3
    CONFIG_NET_SCH_FQ CONFIG_NET_SCH_FQ_CODEL CONFIG_NET_SCH_CAKE CONFIG_NET_SCH_PIE CONFIG_NET_SCH_FQ_PIE
    CONFIG_IP_NF_TARGET_TTL CONFIG_IP6_NF_TARGET_HL CONFIG_IP6_NF_MATCH_HL
    CONFIG_BPF_STREAM_PARSER
    CONFIG_IP_SET CONFIG_IP_SET_BITMAP_IP CONFIG_IP_SET_BITMAP_IPMAC CONFIG_IP_SET_BITMAP_PORT
    CONFIG_IP_SET_HASH_IP CONFIG_IP_SET_HASH_IPMARK CONFIG_IP_SET_HASH_IPPORT
    CONFIG_IP_SET_HASH_IPPORTIP CONFIG_IP_SET_HASH_IPPORTNET CONFIG_IP_SET_HASH_IPMAC
    CONFIG_IP_SET_HASH_MAC CONFIG_IP_SET_HASH_NETPORTNET CONFIG_IP_SET_HASH_NET
    CONFIG_IP_SET_HASH_NETNET CONFIG_IP_SET_HASH_NETPORT CONFIG_IP_SET_HASH_NETIFACE
    CONFIG_IP_SET_LIST_SET CONFIG_NETFILTER_XT_MATCH_ADDRTYPE CONFIG_NETFILTER_XT_SET
    CONFIG_IP6_NF_NAT CONFIG_IP6_NF_TARGET_MASQUERADE
    CONFIG_TMPFS_XATTR CONFIG_TMPFS_POSIX_ACL CONFIG_NTSYNC
    CONFIG_SYSVIPC CONFIG_DEVTMPFS CONFIG_PID_NS CONFIG_POSIX_MQUEUE
    CONFIG_NETFILTER_XT_TARGET_REJECT CONFIG_NETFILTER_XT_TARGET_LOG
    CONFIG_NETFILTER_XT_MATCH_RECENT CONFIG_USER_NS CONFIG_MACVLAN
    CONFIG_LTO_CLANG CONFIG_LTO_CLANG_THIN
    CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE CONFIG_OPTIMIZE_INLINING CONFIG_TRACEPOINTS
  )
  local key
  for key in "${required[@]}"; do
    grep -Fqx "$key=y" "$config_file" || die "WildKernels feature was dropped by olddefconfig: $key"
  done
  grep -Fqx 'CONFIG_IP_SET_MAX=65534' "$config_file" || die "CONFIG_IP_SET_MAX did not survive olddefconfig"
  grep -Fqx 'CONFIG_FRAME_WARN=0' "$config_file" || die "CONFIG_FRAME_WARN did not survive olddefconfig"
  grep -Eq '^CONFIG_LSM="[^"]*baseband_guard' "$config_file" || die "Baseband Guard is missing from the final CONFIG_LSM order"
  {
    echo "final_config=$config_file"
    echo "config_validation=passed"
    for key in "${required[@]}"; do grep -Fqx "$key=y" "$config_file" && echo "$key=y"; done
  } >> "$PROOF"
  note "Final OnePlus Open feature configuration verified."
}

case "$MODE" in
  apply) apply_features ;;
  verify) verify_config "${3:-$KERNEL_ROOT/out/.config}" ;;
  *) die "Unknown mode '$MODE' (expected apply or verify)" ;;
esac
