#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FEATURES="$ROOT/scripts/apply-wildkernels-features.sh"
COMPILE="$ROOT/scripts/compile-kernel.sh"
WORKFLOW="$ROOT/.github/workflows/validate.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }

bash -n "$FEATURES" || fail "WildKernels feature integration script has invalid Bash syntax"
grep -Fq 'PATCHES_COMMIT="b61ceb600da12ef1093597d8a4dfc15d0297b3c1"' "$FEATURES" || fail "kernel patches source must be pinned"
grep -Fq 'BBG_COMMIT="028ff7fd509e2104596da7cc1ef8e6ce2a0c9082"' "$FEATURES" || fail "BBG source must be pinned"
grep -Fq 'PROFILE_ID" == "sm8550-oneplus-open-crdroid"' "$COMPILE" || fail "feature import must be scoped to OnePlus Open crDroid"
for feature in CONFIG_BBG CONFIG_TCP_CONG_BBR CONFIG_TCP_CONG_BBR3 CONFIG_NET_SCH_CAKE CONFIG_NET_SCH_PIE CONFIG_IP_SET CONFIG_IP6_NF_NAT CONFIG_NTSYNC CONFIG_SYSVIPC CONFIG_TMPFS_XATTR CONFIG_TMPFS_POSIX_ACL CONFIG_LTO_CLANG_THIN CONFIG_OPTIMIZE_INLINING; do
  grep -Fq "$feature" "$FEATURES" || fail "missing WildKernels feature: $feature"
done
for patch in gki_ptrace.patch common/bbrv3/0001-net-tcp-backport-BBRv3-to-android13-5.15.patch common/droidspaces/fix_sysvipc_kabi_1_2_3.patch common/ntsync/ntsync_compat_android13-5.15.patch common/unicode_bypass_fix_6.1-.patch oneplus/module_overlay/0001-module-Add-module-intercept-and-overlay-mechanism-android13-5.15.patch; do
  grep -Fq "$patch" "$FEATURES" || fail "missing compatibility patch mapping: $patch"
done
grep -Fq 'apply-wildkernels-features.sh" "$PWD" apply' "$COMPILE" || fail "feature integration is not invoked before defconfig"
grep -Fq 'apply-wildkernels-features.sh" "$PWD" verify' "$COMPILE" || fail "final config verification is not invoked"
grep -Fq 'baseband_guard' "$FEATURES" || fail "BBG LSM registration is not verified"
grep -Fq 'bash scripts/tests/wildkernels-features-test.sh' "$WORKFLOW" || fail "CI does not run WildKernels feature integration test"
echo "PASS: WildKernels OnePlus Open feature integration wiring"
