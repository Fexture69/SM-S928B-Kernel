#!/usr/bin/env bash
#
# check-defconfig-parity.sh — assert our gki_defconfig differs from pristine Samsung
# source ONLY by the allowlisted protection and networking symbols.
#
# The whole premise of Phase 1 is: compile *vanilla* Samsung source, changing the minimum
# needed to boot — plus any explicitly reviewed, KMI-safe built-in features documented in
# docs/DECISIONS.md. This check enforces that premise mechanically. If a future edit flips
# any unallowlisted CONFIG symbol in gki_defconfig, the build fails here (cheaply, before
# the 40-minute compile) instead of shipping a surprise.
#
# Scope (be honest about it): this compares the *source* defconfig against the vanilla
# import. It proves we did not hand-edit any unallowlisted symbol. It does NOT prove the
# final built .config is identical elsewhere (Kconfig dependencies can ripple) — that is
# verified separately against the device's /proc/config.gz. This guard is the build-time
# half; verify-hw.sh + a config.gz diff are the on-device half.
#
# Usage:  scripts/check-defconfig-parity.sh [BASELINE_REF]
#   BASELINE_REF defaults to "vanilla"; CI passes the fetched ref (e.g. FETCH_HEAD).

set -euo pipefail

BASE_REF="${1:-vanilla}"
CFG="kernel_platform/common/arch/arm64/configs/gki_defconfig"

# Symbols allowed to differ in defconfig:
# 1) Samsung/Android boot- or module-load-blocking protections, neutralized at level 1
#    (defconfig) per CLAUDE.md and documented in docs/FACTS.md §0.4 and docs/DECISIONS.md:
#   UH/RKP/KDP        — Samsung micro-hypervisor + Realtime Kernel Protection + KDP
#   SECURITY_DEFEX    — Samsung DEFEX LSM
#   PROCA             — Samsung process authentication
#   FIVE              — Samsung file integrity
#   MODULE_SIG_PROTECT— Android GKI module protection (rejects foreign-signed GKI modules)
# 2) KMI-safe in-tree TCP congestion control algorithms and AQM qdiscs (built-in =y;
#    TCP_CONG_BIC explicitly disabled because it defaults to =m under TCP_CONG_ADVANCED):
#   TCP_CONG_{ADVANCED,BIC,WESTWOOD,HTCP,VENO,CDG,BBR}
#   NET_SCH_{CAKE,PIE,FQ_PIE}
ALLOW_RE='^(UH|RKP|KDP|SECURITY_DEFEX|PROCA|FIVE|MODULE_SIG_PROTECT|TCP_CONG_(ADVANCED|BIC|WESTWOOD|HTCP|VENO|CDG|BBR)|NET_SCH_(CAKE|PIE|FQ_PIE))$'

if ! git rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null; then
  echo "ERROR: baseline ref '${BASE_REF}' not found. In CI, fetch it first:"
  echo "       git fetch --no-tags --depth=1 origin vanilla && $0 FETCH_HEAD"
  exit 2
fi

echo "Comparing $CFG  (working tree)  vs  ${BASE_REF}"

# Collect the set of CONFIG symbols whose defconfig line changed vs the baseline.
changed="$(git diff "${BASE_REF}" -- "$CFG" \
  | grep -E '^[+-](CONFIG_|# CONFIG_)' \
  | sed -E 's/^[+-]//; s/^# //; s/ is not set$//; s/=.*$//; s/^CONFIG_//' \
  | sort -u || true)"

if [ -z "$changed" ]; then
  echo "No defconfig symbol changes vs baseline. PASS."
  exit 0
fi

echo "Changed defconfig symbols:"; echo "$changed" | sed 's/^/  CONFIG_/'

bad=0
while IFS= read -r sym; do
  [ -z "$sym" ] && continue
  if ! printf '%s\n' "$sym" | grep -qE "$ALLOW_RE"; then
    echo "  ✗ DISALLOWED: CONFIG_$sym is not in the defconfig allowlist"
    bad=1
  fi
done <<EOF
$changed
EOF

if [ "$bad" -ne 0 ]; then
  echo ""
  echo "FAIL: gki_defconfig changed a symbol outside the defconfig allowlist."
  echo "      If this change is intentional, add the symbol to ALLOW_RE in $0"
  echo "      and record why in docs/DECISIONS.md — do not loosen it silently."
  exit 1
fi

echo "PASS: every defconfig change is an allowlisted symbol."
