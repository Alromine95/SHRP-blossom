#!/usr/bin/env bash
# Android 16 QPR2 -> Android 17 / LineageOS 24 whole-stack migration auditor
# Safe-by-default: READ-ONLY. It does not rewrite source files, repos, manifests, blobs, or partitions.
set -u -o pipefail

SCRIPT_VERSION="2.0.0"
TREE=""
SOURCE_ROOT=""
REPORT=""
VINTF_ROOT=""
TARGET_BRANCH="lineage-24.0"
TARGET_SDK="37"
TARGET_FCM_MIN="7"
NETWORK=0
RUN_CHECKVINTF=1
RUN_ELF=1
STRICT=0
QUIET=0

PASS=0; WARN=0; ERR=0; INFO=0

usage() {
  cat <<USAGE
Usage: $0 [options]

Whole-stack Android 16 QPR2 -> Android 17 / LineageOS 24 migration auditor.
READ-ONLY: no automatic edits, repo resets, downloads, or flashing.

Required:
  --tree PATH              Device tree path, e.g. device/xiaomi/blossom
  --source PATH            Android source root (recommended), e.g. ~/android/lineage

Optional:
  --vendor PATH             Vendor tree path, e.g. vendor/xiaomi/blossom
  --kernel PATH             Kernel source path, e.g. kernel/xiaomi/mt6765
  --report PATH             Report path (default: <tree>/a17-migration-report.txt)
  --vintf-root PATH         Extracted root with system/vendor/odm for checkvintf
  --first-api N             Override ro.product.first_api_level for checkvintf
  --sku VALUE               Override ro.boot.product.hardware.sku for checkvintf
  --kernel-vintf VALUE      checkvintf --kernel argument, usually VERSION:CONFIG
  --target-branch NAME      Default: lineage-24.0
  --target-sdk N            Default: 37
  --target-fcm-min N        Default: 7 (current LineageOS 24 window)
  --network                 Query configured remotes for target branch availability
  --no-checkvintf           Skip checkvintf
  --no-elf                  Skip vendor ELF scan
  --strict                  Exit 1 on warnings too
  --quiet                   Reduce terminal output; report still written
  -h, --help                Help

Examples:
  $0 --tree device/xiaomi/blossom --source ~/android/lineage
  $0 --tree device/xiaomi/blossom --source ~/android/lineage --vendor vendor/xiaomi/blossom --kernel kernel/xiaomi/mt6765
  $0 --tree device/xiaomi/blossom --source ~/android/lineage --vintf-root /path/to/stock-root --network

What it audits:
  device tree, vendor tree/blobs, kernel source/config, MediaTek common repos,
  sepolicy, VINTF/FCM, AIDL/HIDL declarations, properties, extract-utils,
  lineage.dependencies, .repo/local_manifests, AOSP/Lineage build repos,
  partition/boot configuration, ELF basics, build/VINTF tooling, and migration risks.
USAGE
}

# ---------- argument parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tree) TREE="$2"; shift 2 ;;
    --source) SOURCE_ROOT="$2"; shift 2 ;;
    --vendor) VENDOR_TREE="$2"; shift 2 ;;
    --kernel) KERNEL_TREE="$2"; shift 2 ;;
    --report) REPORT="$2"; shift 2 ;;
    --vintf-root) VINTF_ROOT="$2"; shift 2 ;;
    --first-api) VINTF_FIRST_API="$2"; shift 2 ;;
    --sku) VINTF_SKU="$2"; shift 2 ;;
    --kernel-vintf) VINTF_KERNEL="$2"; shift 2 ;;
    --target-branch) TARGET_BRANCH="$2"; shift 2 ;;
    --target-sdk) TARGET_SDK="$2"; shift 2 ;;
    --target-fcm-min) TARGET_FCM_MIN="$2"; shift 2 ;;
    --network) NETWORK=1; shift ;;
    --no-checkvintf) RUN_CHECKVINTF=0; shift ;;
    --no-elf) RUN_ELF=0; shift ;;
    --strict) STRICT=1; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

: "${VENDOR_TREE:=}"
: "${KERNEL_TREE:=}"
: "${VINTF_FIRST_API:=}"
: "${VINTF_SKU:=}"
: "${VINTF_KERNEL:=}"

if [[ -z "$TREE" ]]; then
  echo "ERROR: --tree is required" >&2
  usage >&2
  exit 2
fi

TREE="$(realpath -m "$TREE")"
[[ -n "$SOURCE_ROOT" ]] && SOURCE_ROOT="$(realpath -m "$SOURCE_ROOT")"
[[ -n "$VENDOR_TREE" ]] && VENDOR_TREE="$(realpath -m "$VENDOR_TREE")"
[[ -n "$KERNEL_TREE" ]] && KERNEL_TREE="$(realpath -m "$KERNEL_TREE")"
[[ -n "$VINTF_ROOT" ]] && VINTF_ROOT="$(realpath -m "$VINTF_ROOT")"

[[ -d "$TREE" ]] || { echo "ERROR: device tree does not exist: $TREE" >&2; exit 2; }
if [[ -n "$SOURCE_ROOT" && ! -d "$SOURCE_ROOT" ]]; then
  echo "ERROR: --source does not exist: $SOURCE_ROOT" >&2; exit 2
fi

if [[ -z "$REPORT" ]]; then
  REPORT="$TREE/a17-migration-report.txt"
elif [[ "$REPORT" != /* ]]; then
  REPORT="$(pwd)/$REPORT"
fi
mkdir -p "$(dirname "$REPORT")"
: > "$REPORT"

# ---------- output helpers ----------
say() {
  printf '%s\n' "$*" >> "$REPORT"
  (( QUIET == 0 )) && printf '%s\n' "$*"
}

result() {
  local level="$1"; shift
  local msg="$*"
  case "$level" in
    PASS) ((PASS++)) ;;
    WARN) ((WARN++)) ;;
    ERROR) ((ERR++)) ;;
    INFO) ((INFO++)) ;;
  esac
  printf '[%-5s] %s\n' "$level" "$msg" >> "$REPORT"
  (( QUIET == 0 )) && printf '[%-5s] %s\n' "$level" "$msg"
}

section() {
  say ""
  say "=================================================================="
  say "$1"
  say "=================================================================="
}

# ---------- filesystem helpers ----------
find_file_under() {
  local root="$1" name="$2"
  [[ -d "$root" ]] || return 0
  find "$root" -type f -name "$name" \
    -not -path '*/.git/*' -not -path '*/out/*' -not -path '*/.repo/*' \
    -not -path '*/prebuilts/*' -print 2>/dev/null | head -n 1
}

search_files() {
  local root="$1"
  shift
  [[ -d "$root" ]] || return 0
  find "$root" -type f "$@" \
    -not -path '*/.git/*' -not -path '*/out/*' -not -path '*/.repo/*' \
    -not -path '*/prebuilts/*' -print 2>/dev/null
}

grep_tree() {
  local root="$1" pattern="$2" max="${3:-100}"
  [[ -d "$root" ]] || return 0
  grep -RInE \
    --exclude-dir=.git --exclude-dir=out --exclude-dir=.repo --exclude-dir=prebuilts \
    --exclude-dir=node_modules --exclude='*.pyc' --exclude='*.a17-migration-report*' \
    -- "$pattern" "$root" 2>/dev/null | head -n "$max" || true
}

count_tree() {
  local root="$1"
  [[ -d "$root" ]] || { echo 0; return; }
  find "$root" -type f -not -path '*/.git/*' -not -path '*/out/*' -not -path '*/.repo/*' -not -path '*/prebuilts/*' 2>/dev/null | wc -l | tr -d ' '
}

repo_root_for() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null || true
}

repo_branch_for() {
  git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null || echo DETACHED
}

repo_commit_for() {
  git -C "$1" rev-parse --short HEAD 2>/dev/null || echo UNKNOWN
}

repo_status_for() {
  git -C "$1" status --porcelain 2>/dev/null || true
}

# ---------- Python helper ----------
PY="$(command -v python3 2>/dev/null || true)"

# ---------- initial report ----------
say "Android 17 / LineageOS 24 Whole-Stack Migration Audit"
say "Version:        $SCRIPT_VERSION"
say "Device tree:   $TREE"
[[ -n "$SOURCE_ROOT" ]] && say "Source root:    $SOURCE_ROOT"
[[ -n "$VENDOR_TREE" ]] && say "Vendor tree:    $VENDOR_TREE"
[[ -n "$KERNEL_TREE" ]] && say "Kernel tree:    $KERNEL_TREE"
say "Target branch:  $TARGET_BRANCH"
say "Target SDK:     $TARGET_SDK"
say "Target FCM >=:  $TARGET_FCM_MIN"
say "Date:           $(date -Is)"
say "Mode:           READ-ONLY / NON-DESTRUCTIVE"

# ---------- discover likely paths ----------
BC="$(find_file_under "$TREE" BoardConfig.mk)"
DMK="$(find_file_under "$TREE" device.mk)"
AP="$(find_file_under "$TREE" AndroidProducts.mk)"
MAN="$(find_file_under "$TREE" manifest.xml)"
DEP="$(find_file_under "$TREE" lineage.dependencies)"
PROPFILE="$(find_file_under "$TREE" proprietary-files.txt)"
EXTRACTPY="$(find_file_under "$TREE" extract-files.py)"
SETUPPY="$(find_file_under "$TREE" setup-makefiles.py)"

if [[ -z "$SOURCE_ROOT" ]]; then
  # Useful when called from the source root.
  if [[ -d "$(pwd)/device" && -d "$(pwd)/build" ]]; then
    SOURCE_ROOT="$(pwd)"
  fi
fi

# Infer vendor/kernel from device-tree references where possible.
if [[ -z "$VENDOR_TREE" && -n "$SOURCE_ROOT" ]]; then
  vpath="$(grep_tree "$TREE" 'vendor/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' 80 | sed -nE 's/.*(vendor\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+).*/\1/p' | sort -u | while IFS= read -r p; do [[ -d "$SOURCE_ROOT/$p" ]] && { echo "$p"; break; }; done)"
  if [[ -n "$vpath" ]]; then
    VENDOR_TREE="$SOURCE_ROOT/$vpath"
    result INFO "Inferred vendor tree from device-tree references: $VENDOR_TREE"
  fi
fi

if [[ -z "$KERNEL_TREE" && -n "$SOURCE_ROOT" && -n "$BC" ]]; then
  kpath="$(grep -hE '^[[:space:]]*TARGET_KERNEL_SOURCE[[:space:]]*[:+?]?=' "$BC" | tail -n1 | sed -E 's/.*=[[:space:]]*//')"
  kpath="${kpath//\$(DEVICE_PATH)/${TREE#$SOURCE_ROOT/}}"
  kpath="${kpath#\$(DEVICE_PATH)/}"
  [[ -d "$SOURCE_ROOT/$kpath" ]] && KERNEL_TREE="$SOURCE_ROOT/$kpath"
fi

section "0. Overall source-tree topology"
[[ -n "$SOURCE_ROOT" ]] && result PASS "Android source root provided: $SOURCE_ROOT" || result WARN "No --source supplied; whole-stack/AOSP checks will be limited"
for p in build/make build/soong system/libvintf hardware/interfaces system/sepolicy vendor/lineage; do
  if [[ -n "$SOURCE_ROOT" && -d "$SOURCE_ROOT/$p" ]]; then
    result PASS "Found source repo/path: $p"
  else
    result WARN "Missing source path: $p"
  fi
done
for p in device vendor kernel hardware; do
  if [[ -n "$SOURCE_ROOT" && -d "$SOURCE_ROOT/$p" ]]; then
    result PASS "Top-level source directory present: $p"
  else
    result WARN "Top-level source directory missing: $p"
  fi
done

section "1. Device tree inventory"
[[ -n "$BC" ]] && result PASS "BoardConfig.mk: $BC" || result ERROR "BoardConfig.mk not found"
[[ -n "$DMK" ]] && result PASS "device.mk: $DMK" || result WARN "device.mk not found"
[[ -n "$AP" ]] && result PASS "AndroidProducts.mk: $AP" || result WARN "AndroidProducts.mk not found"
[[ -n "$MAN" ]] && result PASS "manifest.xml: $MAN" || result WARN "manifest.xml not found"
[[ -n "$DEP" ]] && result INFO "lineage.dependencies: $DEP" || result INFO "No lineage.dependencies found"
[[ -n "$PROPFILE" ]] && result PASS "proprietary-files.txt: $PROPFILE" || result WARN "No proprietary-files.txt found"
[[ -n "$EXTRACTPY" ]] && result PASS "Python extract-files.py found (Lineage 22+ style)" || result WARN "extract-files.py not found"
[[ -n "$SETUPPY" ]] && result PASS "Python setup-makefiles.py found" || result WARN "setup-makefiles.py not found"
result INFO "Device tree file count: $(count_tree "$TREE")"

if git -C "$TREE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  result INFO "Device repo branch: $(repo_branch_for "$TREE")"
  result INFO "Device repo commit: $(repo_commit_for "$TREE")"
  [[ -z "$(repo_status_for "$TREE")" ]] && result PASS "Device repo clean" || result WARN "Device repo has uncommitted changes"
else
  result WARN "Device tree is not itself a Git worktree"
fi

if [[ -n "$BC" ]]; then
  for key in TARGET_ARCH TARGET_ARCH_VARIANT TARGET_CPU_VARIANT TARGET_BOARD_PLATFORM BOARD_BOOT_HEADER_VERSION BOARD_BOOTIMG_HEADER_VERSION BOARD_KERNEL_PAGESIZE PRODUCT_SHIPPING_API_LEVEL BOARD_SHIPPING_API_LEVEL BOARD_API_LEVEL TARGET_KERNEL_SOURCE TARGET_KERNEL_CONFIG; do
    val="$(grep -hE "^[[:space:]]*$key[[:space:]]*[:+?]?=" "$BC" 2>/dev/null | tail -n1 | sed -E 's/^[^=]*=[[:space:]]*//')"
    [[ -n "$val" ]] && result INFO "$key = $val"
  done
fi

section "2. Android 17 / Lineage 24 platform baseline"
if [[ -n "$SOURCE_ROOT" ]]; then
  VDF="$SOURCE_ROOT/build/make/core/version_defaults.mk"
  if [[ -f "$VDF" ]]; then
    sdk="$(grep -E '^[[:space:]]*PLATFORM_SDK_VERSION[[:space:]]*:?=' "$VDF" | tail -n1 | sed -E 's/.*=[[:space:]]*//')"
    pv="$(grep -E '^[[:space:]]*PLATFORM_VERSION[[:space:]]*:?=' "$VDF" | tail -n1 | sed -E 's/.*=[[:space:]]*//')"
    [[ -n "$sdk" ]] && result INFO "PLATFORM_SDK_VERSION = $sdk"
    [[ -n "$pv" ]] && result INFO "PLATFORM_VERSION = $pv"
    [[ "$sdk" == "$TARGET_SDK" ]] && result PASS "Platform SDK matches target $TARGET_SDK" || result ERROR "Platform SDK does not match target $TARGET_SDK"
  else
    result ERROR "Missing build/make/core/version_defaults.mk"
  fi
  if [[ -d "$SOURCE_ROOT/hardware/interfaces/compatibility_matrices" ]]; then
    matrices="$(find "$SOURCE_ROOT/hardware/interfaces/compatibility_matrices" -maxdepth 1 -type f -name 'compatibility_matrix*.xml' -print 2>/dev/null | sort || true)"
    if [[ -n "$matrices" ]]; then
      result INFO "Framework compatibility matrices found: $(printf '%s\n' "$matrices" | wc -l | tr -d ' ')"
      fcm_levels="$(printf '%s\n' "$matrices" | sed -nE 's/.*compatibility_matrix\.([0-9]+)(\..*)?\.xml/\1/p' | sort -n -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
      [[ -n "$fcm_levels" ]] && result INFO "Detected generic FCM levels from filenames: $fcm_levels"
      a17f="$(find "$SOURCE_ROOT/hardware/interfaces/compatibility_matrices" -maxdepth 1 -type f -name '*android17*.xml' -print -quit 2>/dev/null || true)"
      [[ -n "$a17f" ]] && result PASS "Android 17-named FCM matrix found: $a17f" || result INFO "No filename containing android17; inspect branch-specific matrix naming"
    else
      result ERROR "No framework compatibility matrices found"
    fi
  else
    result ERROR "Missing hardware/interfaces/compatibility_matrices"
  fi
  for repo in build/make build/soong system/libvintf hardware/interfaces system/sepolicy; do
    if [[ -d "$SOURCE_ROOT/$repo/.git" || -f "$SOURCE_ROOT/$repo/.git" ]]; then
      result INFO "$repo branch: $(repo_branch_for "$SOURCE_ROOT/$repo")"
    fi
  done
else
  result INFO "AOSP/Lineage platform checks skipped without --source"
fi

section "3. Device shipping/first API versus framework API"
ship=""
for f in "$BC" "$DMK"; do
  [[ -f "$f" ]] || continue
  x="$(grep -hE '^[[:space:]]*(PRODUCT|BOARD)_SHIPPING_API_LEVEL[[:space:]]*[:+?]?=' "$f" | tail -n1 | sed -E 's/.*=[[:space:]]*//')"
  [[ -n "$x" ]] && ship="$x"
done
if [[ -n "$ship" ]]; then
  result INFO "Tree shipping API setting = $ship"
  if [[ "$ship" == "$TARGET_SDK" ]]; then
    result WARN "Shipping API equals framework SDK $TARGET_SDK; verify this is intentional instead of blindly using the framework API"
  else
    result PASS "Shipping API is distinct from framework SDK (review against real stock first API)"
  fi
else
  result WARN "No PRODUCT_SHIPPING_API_LEVEL / BOARD_SHIPPING_API_LEVEL found"
fi

section "4. VINTF / FCM — device, vendor, and framework together"
if [[ -n "$MAN" ]]; then
  target="$(grep -oE 'target-level="[0-9]+"' "$MAN" | head -n1 | sed -E 's/[^0-9]//g')"
  [[ -n "$target" ]] && result INFO "Device manifest target-level = $target"
  if [[ -n "$target" && "$target" -lt "$TARGET_FCM_MIN" ]]; then
    result ERROR "Device manifest target-level $target is below Lineage target minimum $TARGET_FCM_MIN"
    result INFO "Do NOT just increment target-level; align the device/common/vendor VINTF interfaces first"
  elif [[ -n "$target" ]]; then
    result PASS "Device manifest target-level is within configured Lineage window"
  fi
fi

if [[ -n "$VENDOR_TREE" && -d "$VENDOR_TREE" ]]; then
  stock_vintf="$(find "$VENDOR_TREE" -type f -path '*/etc/vintf/manifest*.xml' -print -quit 2>/dev/null || true)"
  if [[ -n "$stock_vintf" ]]; then
    vt="$(grep -oE 'target-level="[0-9]+"' "$stock_vintf" | head -n1 | sed -E 's/[^0-9]//g')"
    [[ -n "$vt" ]] && result INFO "Vendor tree manifest target-level = $vt ($stock_vintf)"
    if [[ -n "$vt" && "$vt" -lt "$TARGET_FCM_MIN" ]]; then
      result ERROR "Vendor manifest FCM $vt is below configured Lineage 24 minimum $TARGET_FCM_MIN"
    fi
  else
    result INFO "No generated vendor/etc/vintf manifest found under vendor tree; stock vendor root can be supplied with --vintf-root"
  fi
fi

# Enumerate HALs from device manifest and framework compatibility matrices.
if [[ -n "$MAN" ]]; then
  hidl_count="$(grep -c '<hal[^>]*format="hidl"' "$MAN" 2>/dev/null || true)"
  aidl_count="$(grep -c '<hal[^>]*format="aidl"' "$MAN" 2>/dev/null || true)"
  result INFO "Device manifest HIDL HAL blocks: $hidl_count"
  result INFO "Device manifest AIDL HAL blocks: $aidl_count"
  if (( aidl_count > 0 )); then result INFO "AIDL HALs present — verify frozen versions against target branch"; fi
  if (( hidl_count > 0 )); then result INFO "Legacy HIDL HALs present — do not mass-convert them merely for Android 17"; fi
fi

section "5. VINTF bypasses / validation suppression"
for pat in \
  'PRODUCT_ENFORCE_VINTF_MANIFEST[[:space:]]*[:+?]?=[[:space:]]*false' \
  'PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS[[:space:]]*[:+?]?=[[:space:]]*false' \
  'SKIP_ABI_CHECKS' \
  'ALLOW_MISSING_DEPENDENCIES' \
  'BUILD_BROKEN_[A-Z0-9_]+'; do
  hits="$(grep_tree "$TREE" "$pat" 80)"
  if [[ -n "$hits" ]]; then
    result WARN "Device-tree workaround detected: $pat"
    printf '%s\n' "$hits" >> "$REPORT"
    (( QUIET == 0 )) && printf '%s\n' "$hits"
  fi
done
if [[ -n "$VENDOR_TREE" ]]; then
  hits="$(grep_tree "$VENDOR_TREE" 'BUILD_BROKEN_[A-Z0-9_]+|ALLOW_MISSING_DEPENDENCIES|SKIP_ABI_CHECKS' 80)"
  [[ -n "$hits" ]] && { result WARN "Vendor tree also contains build workarounds"; printf '%s\n' "$hits" >> "$REPORT"; (( QUIET == 0 )) && printf '%s\n' "$hits"; }
fi

section "6. Vendor tree / proprietary blob completeness"
if [[ -n "$VENDOR_TREE" && -d "$VENDOR_TREE" ]]; then
  result PASS "Vendor tree exists: $VENDOR_TREE"
  result INFO "Vendor file count: $(count_tree "$VENDOR_TREE")"
  for f in BoardConfigVendor.mk Android.mk Android.bp vendor.mk proprietary-files.txt; do
    p="$(find_file_under "$VENDOR_TREE" "$f")"
    [[ -n "$p" ]] && result INFO "Vendor has $f: $p"
  done
  for d in bin bin/hw lib lib64 etc etc/vintf etc/selinux firmware; do
    [[ -d "$VENDOR_TREE/$d" ]] && result INFO "Vendor subtree present: $d"
  done
  # Vendor build properties: collect API/VNDK clues.
  bp="$(find "$VENDOR_TREE" -type f \( -name 'build.prop' -o -name 'vendor.prop' -o -name '*build*.prop' \) -print -quit 2>/dev/null || true)"
  if [[ -n "$bp" ]]; then
    for k in ro.vendor.build.version.sdk ro.vndk.version ro.board.first_api_level ro.product.first_api_level ro.vendor.build.version.release; do
      val="$(grep -hE "^[[:space:]]*$k=" "$bp" | tail -n1 | cut -d= -f2- || true)"
      [[ -n "$val" ]] && result INFO "$k = $val ($bp)"
    done
  fi
else
  result WARN "Vendor tree not supplied/found. For a real vendor audit pass --vendor vendor/<oem>/<device>"
fi

if [[ -n "$PROPFILE" ]]; then
  result INFO "Proprietary list entries (non-comment/non-empty): $(grep -vE '^[[:space:]]*(#|$)' "$PROPFILE" 2>/dev/null | wc -l | tr -d ' ')"
  if [[ -n "$VENDOR_TREE" && -d "$VENDOR_TREE/proprietary" ]]; then
    missing=0; checked=0
    while IFS= read -r line; do
      line="${line%%#*}"
      line="${line%%;*}"
      [[ -z "${line//[[:space:]]/}" ]] && continue
      # Skip directives without a blob path.
      [[ "$line" =~ ^- ]] && continue
      target="$line"
      if [[ "$line" == *:* ]]; then target="${line#*:}"; fi
      target="${target%%|*}"
      target="${target//\$(PRODUCT_OUT)/}"
      target="${target#/}"
      # Most generated vendor repos place targets under proprietary/.
      checked=$((checked+1))
      [[ -f "$VENDOR_TREE/proprietary/$target" || -L "$VENDOR_TREE/proprietary/$target" || -f "$VENDOR_TREE/$target" || -L "$VENDOR_TREE/$target" ]] || missing=$((missing+1))
      (( checked >= 5000 )) && break
    done < "$PROPFILE"
    if (( missing == 0 )); then
      result PASS "Checked $checked proprietary-file targets: no obvious missing vendor copies"
    else
      result WARN "Checked $checked proprietary-file targets: $missing targets were not found under vendor tree"
    fi
  fi
fi

section "7. LineageOS extraction tooling"
if [[ -n "$PROPFILE" ]]; then
  if [[ -n "$EXTRACTPY" && -n "$SETUPPY" ]]; then
    result PASS "Device uses Lineage 22+ Python extract-utils templates"
  else
    legacy_ext="$(find "$TREE" -maxdepth 2 -type f -name 'extract-files.sh' -print -quit 2>/dev/null || true)"
    legacy_setup="$(find "$TREE" -maxdepth 2 -type f -name 'setup-makefiles.sh' -print -quit 2>/dev/null || true)"
    if [[ -n "$legacy_ext" || -n "$legacy_setup" ]]; then
      result WARN "Legacy shell extraction scripts detected; LineageOS documentation recommends Python extraction from Lineage 22 onward"
    else
      result ERROR "proprietary-files.txt exists but no supported extraction/setup script was found"
    fi
  fi
else
  result WARN "No proprietary-files.txt means blob reproducibility cannot be validated"
fi

section "8. Lineage dependencies / local manifests / repo graph"
if [[ -n "$DEP" && -n "$PY" ]]; then
  "$PY" - "$DEP" <<'PY' >> "$REPORT"
import json,sys
p=sys.argv[1]
try:
    d=json.load(open(p))
    print(f"[INFO ] Parsed lineage.dependencies entries: {len(d) if isinstance(d,list) else 'non-list'}")
    if isinstance(d,list):
        for x in d[:200]:
            if isinstance(x,dict):
                print("[DEP  ] path=%s repository=%s branch=%s" % (x.get('target_path'), x.get('repository'), x.get('branch') or x.get('revision') or 'default'))
except Exception as e:
    print(f"[WARN ] Could not parse lineage.dependencies: {e}")
PY
  # Mirror the INFO/WARN DEP lines to terminal in normal mode.
  if (( QUIET == 0 )); then
    grep -E '^\[(INFO |DEP  |WARN )\]' "$REPORT" | tail -n 210
  fi
  dep_paths="$("$PY" - "$DEP" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    if isinstance(d,list):
        for x in d:
            if isinstance(x,dict) and x.get('target_path'):
                print(x['target_path'])
except Exception: pass
PY
)"
  if [[ -n "$SOURCE_ROOT" ]]; then
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      [[ -d "$SOURCE_ROOT/$p" ]] && result PASS "Dependency path present: $p" || result ERROR "Dependency path missing: $p"
    done <<< "$dep_paths"
  fi
elif [[ -n "$DEP" ]]; then
  result WARN "lineage.dependencies found but python3 is unavailable for structured parsing"
else
  result INFO "No lineage.dependencies file in device tree"
fi

if [[ -n "$SOURCE_ROOT" && -d "$SOURCE_ROOT/.repo/local_manifests" ]]; then
  xml_count="$(find "$SOURCE_ROOT/.repo/local_manifests" -type f \( -name '*.xml' -o -name '*.xml.gz' \) -print 2>/dev/null | wc -l | tr -d ' ')"
  result INFO "Local manifest files: $xml_count"
  if [[ -n "$PY" ]]; then
    "$PY" - "$SOURCE_ROOT/.repo/local_manifests" "$TARGET_BRANCH" <<'PY' >> "$REPORT"
import os,sys,xml.etree.ElementTree as ET
root=sys.argv[1]; target=sys.argv[2]
for base,_,files in os.walk(root):
  for fn in sorted(files):
    if not fn.endswith('.xml'): continue
    path=os.path.join(base,fn)
    try: tree=ET.parse(path)
    except Exception as e:
      print(f"[WARN ] Invalid manifest XML {path}: {e}"); continue
    for p in tree.findall('.//project'):
      name=p.get('name',''); pathv=p.get('path',''); rev=p.get('revision') or target
      if pathv or name:
        print(f"[MANIF] path={pathv} name={name} revision={rev}")
PY
    if (( QUIET == 0 )); then grep '^\[MANIF\]' "$REPORT" | tail -n 300; fi
  else
    result WARN "python3 unavailable; local manifest XML not parsed"
  fi
else
  result INFO "No .repo/local_manifests directory found"
fi

section "9. AOSP / Lineage common repositories relevant to MediaTek"
if [[ -n "$SOURCE_ROOT" ]]; then
  declare -a CANDIDATE_REPOS=(
    "hardware/mediatek"
    "device/mediatek/sepolicy_vndr"
    "device/mediatek/sepolicy"
    "device/lineage/sepolicy"
    "hardware/lineage"
    "vendor/lineage"
    "system/sepolicy"
    "system/libvintf"
    "hardware/interfaces"
    "build/make"
    "build/soong"
    "tools/extract-utils"
  )
  for p in "${CANDIDATE_REPOS[@]}"; do
    if [[ -d "$SOURCE_ROOT/$p" ]]; then
      if [[ -d "$SOURCE_ROOT/$p/.git" || -f "$SOURCE_ROOT/$p/.git" ]]; then
        result PASS "$p present (branch $(repo_branch_for "$SOURCE_ROOT/$p"))"
      else
        result INFO "$p present (not a standalone Git worktree; repo may be manifest-managed)"
      fi
    else
      # Only make MediaTek-specific missing repos errors if the device tree actually references them.
      ref="$(grep_tree "$TREE" "(^|[ /])${p//\//\/}([ /]|$)" 5)"
      if [[ -n "$ref" ]]; then
        result ERROR "$p is referenced by device tree but missing from source"
      else
        result INFO "$p not present and not directly referenced by device tree"
      fi
    fi
  done
else
  result INFO "Common-repo graph requires --source"
fi

# Inspect explicit includes/references to common trees.
common_refs="$(grep_tree "$TREE" 'device/mediatek/(sepolicy|sepolicy_vndr)|hardware/mediatek|hardware/lineage|device/lineage|vendor/lineage' 180)"
if [[ -n "$common_refs" ]]; then
  result INFO "Common-tree references from device tree:"
  printf '%s\n' "$common_refs" >> "$REPORT"
  (( QUIET == 0 )) && printf '%s\n' "$common_refs"
fi

section "10. Target-branch consistency across repos"
check_repo_branch() {
  local label="$1" path="$2"
  [[ -d "$path" ]] || return 0
  if git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    b="$(repo_branch_for "$path")"
    case "$b" in
      "$TARGET_BRANCH") result PASS "$label branch=$b" ;;
      DETACHED) result WARN "$label is detached at $(repo_commit_for "$path"); verify manifest pins the intended $TARGET_BRANCH commit" ;;
      *) result WARN "$label branch=$b, target is $TARGET_BRANCH" ;;
    esac
  fi
}
check_repo_branch "device" "$TREE"
[[ -n "$VENDOR_TREE" ]] && check_repo_branch "vendor" "$VENDOR_TREE"
[[ -n "$KERNEL_TREE" ]] && check_repo_branch "kernel" "$KERNEL_TREE"
if [[ -n "$SOURCE_ROOT" ]]; then
  for p in vendor/lineage hardware/mediatek device/mediatek/sepolicy_vndr device/lineage/sepolicy tools/extract-utils; do
    [[ -d "$SOURCE_ROOT/$p" ]] && check_repo_branch "$p" "$SOURCE_ROOT/$p"
  done
fi

section "11. Network branch availability (optional)"
if (( NETWORK == 1 )); then
  if ! command -v git >/dev/null 2>&1; then
    result WARN "git not available; cannot query remotes"
  else
    checked_paths=()
    for p in "$TREE" "$VENDOR_TREE" "$KERNEL_TREE"; do
      [[ -n "$p" && -d "$p" ]] || continue
      if git -C "$p" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        url="$(git -C "$p" remote get-url origin 2>/dev/null || true)"
        [[ -z "$url" ]] && { result INFO "No origin remote for $p"; continue; }
        if git ls-remote --exit-code --heads "$url" "refs/heads/$TARGET_BRANCH" >/dev/null 2>&1; then
          result PASS "$p remote has $TARGET_BRANCH"
        else
          result INFO "$p remote does not expose $TARGET_BRANCH (kernel trees often intentionally stay on another branch)"
        fi
      fi
    done
  fi
else
  result INFO "Network branch probing disabled; use --network when desired"
fi

section "12. Kernel source / configuration"
if [[ -n "$KERNEL_TREE" && -d "$KERNEL_TREE" ]]; then
  result PASS "Kernel tree: $KERNEL_TREE"
  result INFO "Kernel file count: $(count_tree "$KERNEL_TREE")"
  if [[ -d "$KERNEL_TREE/.git" || -f "$KERNEL_TREE/.git" ]]; then
    result INFO "Kernel branch: $(repo_branch_for "$KERNEL_TREE")"
    result INFO "Kernel commit: $(repo_commit_for "$KERNEL_TREE")"
  fi
  cfg=""
  if [[ -n "$BC" ]]; then
    cfgname="$(grep -hE '^[[:space:]]*TARGET_KERNEL_CONFIG[[:space:]]*[:+?]?=' "$BC" | tail -n1 | sed -E 's/.*=[[:space:]]*//')"
    [[ -n "$cfgname" ]] && cfg="$cfgname"
  fi
  if [[ -n "$cfg" && -f "$KERNEL_TREE/arch/arm64/configs/$cfg" ]]; then
    result PASS "Kernel defconfig found: arch/arm64/configs/$cfg"
  else
    result WARN "Kernel defconfig not resolved from BoardConfig.mk"
  fi
  for key in CONFIG_ANDROID_BINDER_IPC CONFIG_SECCOMP CONFIG_BPF CONFIG_CGROUPS CONFIG_NAMESPACES CONFIG_DMABUF_HEAPS; do
    f=""
    [[ -n "$cfg" && -f "$KERNEL_TREE/arch/arm64/configs/$cfg" ]] && f="$KERNEL_TREE/arch/arm64/configs/$cfg"
    if [[ -n "$f" ]] && grep -qE "^[[:space:]]*$key=([ym])" "$f"; then
      result PASS "$key enabled in defconfig"
    elif [[ -n "$f" ]]; then
      result WARN "$key not explicitly enabled in defconfig (actual merged .config may differ)"
    fi
  done
  if [[ -f "$KERNEL_TREE/Makefile" ]]; then
    kv="$(grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL)[[:space:]]*=' "$KERNEL_TREE/Makefile" | tr '\n' ' ')"
    result INFO "Kernel Makefile version fields: ${kv%,}"
  fi
else
  result WARN "Kernel tree not supplied/found; pass --kernel for kernel-aware audit"
fi

if [[ -n "$BC" ]]; then
  fake_kernel="$(grep_tree "$TREE" 'ro\.kernel\.version[[:space:]]*[:+?]?=|PRODUCT_PROPERTY_OVERRIDES.*ro\.kernel\.version|PRODUCT_SYSTEM_PROPERTIES.*ro\.kernel\.version' 50)"
  if [[ -n "$fake_kernel" ]]; then
    result WARN "Hard-coded ro.kernel.version override detected"
    printf '%s\n' "$fake_kernel" >> "$REPORT"
    (( QUIET == 0 )) && printf '%s\n' "$fake_kernel"
  else
    result PASS "No hard-coded ro.kernel.version override detected"
  fi
fi

section "13. Boot image / partition geometry"
if [[ -n "$BC" ]]; then
  for key in BOARD_BOOT_HEADER_VERSION BOARD_BOOTIMG_HEADER_VERSION BOARD_KERNEL_PAGESIZE BOARD_INCLUDE_DTB_IN_BOOTIMG BOARD_KERNEL_BASE BOARD_KERNEL_OFFSET BOARD_RAMDISK_OFFSET BOARD_TAGS_OFFSET BOARD_DTB_OFFSET BOARD_SUPER_PARTITION_SIZE BOARD_SUPER_PARTITION_GROUPS BOARD_SYSTEMIMAGE_PARTITION_RESERVED_SIZE BOARD_VENDORIMAGE_PARTITION_RESERVED_SIZE BOARD_PRODUCTIMAGE_PARTITION_RESERVED_SIZE BOARD_SYSTEM_EXTIMAGE_PARTITION_RESERVED_SIZE; do
    val="$(grep -hE "^[[:space:]]*$key[[:space:]]*[:+?]?=" "$BC" | tail -n1 | sed -E 's/^[^=]*=[[:space:]]*//')"
    [[ -n "$val" ]] && result INFO "$key = $val"
  done
  if grep -Eq 'BOARD_BOOT_HEADER_VERSION[[:space:]]*[:+?]?=[[:space:]]*2|BOARD_BOOTIMG_HEADER_VERSION[[:space:]]*[:+?]?=[[:space:]]*2' "$BC"; then
    result PASS "Boot header v2 configured; preserve unless measured hardware data proves otherwise"
  fi
fi

section "14. SELinux / policy stack"
policy_found=0
for root in "$TREE" "$VENDOR_TREE"; do
  [[ -n "$root" && -d "$root" ]] || continue
  for d in sepolicy sepolicy/vendor sepolicy/private sepolicy/public sepolicy_vndr vendor_sepolicy; do
    [[ -d "$root/$d" ]] || continue
    result INFO "SELinux path: $root/$d"
    policy_found=1
  done
done
[[ $policy_found -eq 1 ]] || result WARN "No device/vendor SELinux policy directory found"
perm="$(grep_tree "$TREE" 'setenforce[[:space:]]+0|SELINUX=permissive|androidboot\.selinux=permissive' 80)"
if [[ -n "$perm" ]]; then
  result ERROR "Permissive SELinux/debug bypass detected in device tree"
  printf '%s\n' "$perm" >> "$REPORT"
  (( QUIET == 0 )) && printf '%s\n' "$perm"
else
  result PASS "No obvious permissive SELinux bypass in device tree"
fi
if [[ -n "$SOURCE_ROOT" && -d "$SOURCE_ROOT/system/sepolicy" ]]; then
  result PASS "AOSP system/sepolicy present"
  if [[ -d "$SOURCE_ROOT/device/mediatek/sepolicy_vndr" ]]; then
    result PASS "MediaTek vendor policy common tree present"
  fi
fi

section "15. Properties / namespace / dead-config audit"
# These are high-value migration hotspots, but not all are always wrong.
for pat in \
  'BUILD_BROKEN_VENDOR_PROPERTY_NAMESPACE' \
  'PRODUCT_TARGET_VNDK_VERSION' \
  'BOARD_VNDK_VERSION' \
  'PRODUCT_USE_VNDK' \
  'TARGET_USES_OMX' \
  'TARGET_USES_AAPT2[^\n]*false' \
  'BOARD_VNDK_VERSION' \
  'BOARD_PLATFORM_SECURITY_PATCH'; do
  hits="$(grep_tree "$TREE" "$pat" 120)"
  if [[ -n "$hits" ]]; then
    result WARN "Potential A17 migration hotspot: $pat"
    printf '%s\n' "$hits" >> "$REPORT"
    (( QUIET == 0 )) && printf '%s\n' "$hits"
  fi
done
if [[ -n "$VENDOR_TREE" ]]; then
  hits="$(grep_tree "$VENDOR_TREE" 'PRODUCT_TARGET_VNDK_VERSION|BOARD_VNDK_VERSION|PRODUCT_USE_VNDK|BUILD_BROKEN_VENDOR_PROPERTY_NAMESPACE' 80)"
  [[ -n "$hits" ]] && { result WARN "Legacy/deprecated VNDK/build settings appear in vendor tree"; printf '%s\n' "$hits" >> "$REPORT"; (( QUIET == 0 )) && printf '%s\n' "$hits"; }
fi

section "16. AIDL / HIDL / HAL source compatibility"
for root in "$TREE" "$VENDOR_TREE"; do
  [[ -n "$root" && -d "$root" ]] || continue
  aidl="$(grep_tree "$root" 'interface .*aidl|aidl_interface[[:space:]]*\{|versions:[[:space:]]*\[' 120)"
  hidl="$(grep_tree "$root" 'android\.hardware\.[A-Za-z0-9_.]+/[0-9]+\.[0-9]+|<hal[^>]*format="hidl"' 120)"
  [[ -n "$aidl" ]] && { result INFO "AIDL declarations/source found under $root"; printf '%s\n' "$aidl" >> "$REPORT"; }
  [[ -n "$hidl" ]] && { result INFO "HIDL declarations found under $root"; printf '%s\n' "$hidl" >> "$REPORT"; }
done
if [[ -n "$SOURCE_ROOT" && -d "$SOURCE_ROOT/system/libhidl" ]]; then
  result INFO "system/libhidl present — legacy HIDL compatibility may remain relevant"
fi

section "17. ELF / proprietary binary sanity (optional)"
if (( RUN_ELF == 0 )); then
  result INFO "ELF scan disabled with --no-elf"
elif [[ -n "$VENDOR_TREE" && -d "$VENDOR_TREE" ]]; then
  if command -v readelf >/dev/null 2>&1 || command -v llvm-readelf >/dev/null 2>&1; then
    READELF="$(command -v llvm-readelf 2>/dev/null || command -v readelf 2>/dev/null)"
    total=0; exec_nonpie=0; badarch=0; needed_hits=0
    # Restrict to executable locations to keep runtime sane.
    while IFS= read -r -d '' f; do
      out="$($READELF -h "$f" 2>/dev/null || true)"
      [[ -z "$out" ]] && continue
      ((total++))
      cls="$(printf '%s\n' "$out" | awk -F: '/Class:/{gsub(/ /, "", $2);print $2;exit}')"
      mach="$(printf '%s\n' "$out" | awk -F: '/Machine:/{sub(/^ +/,"",$2);print $2;exit}')"
      [[ "$cls" != "ELF64" && "$f" == *64* ]] && badarch=$((badarch+1))
      typ="$(printf '%s\n' "$out" | awk -F: '/Type:/{gsub(/ /, "", $2);print $2;exit}')"
      # ET_EXEC executables are the clearest non-PIE signal; shared libs are ET_DYN too.
      if [[ "$typ" == *EXEC* ]]; then exec_nonpie=$((exec_nonpie+1)); fi
      if [[ "$f" == *'/hw/'* ]]; then :; fi
      (( total >= 1500 )) && break
    done < <(find "$VENDOR_TREE" -type f \( -path '*/bin/*' -o -path '*/xbin/*' -o -path '*/bin/hw/*' \) -print0 2>/dev/null)
    result INFO "ELF headers inspected: $total vendor executables"
    if (( exec_nonpie > 0 )); then
      result WARN "Found $exec_nonpie ET_EXEC vendor executable(s); Lineage device requirements disallow non-PIE binaries — inspect individually"
    else
      result PASS "No ET_EXEC vendor executables found in scanned locations"
    fi
    (( badarch > 0 )) && result WARN "Some scanned ELF files have an unexpected 64-bit naming/architecture signal; inspect manually"
  else
    result INFO "readelf/llvm-readelf not available; skipped ELF header scan"
  fi
else
  result INFO "ELF scan skipped because vendor tree was not supplied"
fi

section "18. Build-system dry-run / validation tools"
if [[ -n "$SOURCE_ROOT" ]]; then
  CV=""
  for c in \
    "$SOURCE_ROOT/out/host/linux-x86/bin/checkvintf" \
    "$SOURCE_ROOT/out/host/linux-x86/bin/checkvintf_vendor" \
    "$(command -v checkvintf 2>/dev/null || true)"; do
    [[ -x "$c" ]] && { CV="$c"; break; }
  done
  if [[ -n "$CV" ]]; then
    result PASS "checkvintf found: $CV"
    "$CV" --help >/dev/null 2>&1 && result PASS "checkvintf runs" || result WARN "checkvintf exists but --help failed"
  else
    result WARN "checkvintf not built/found; real VINTF validation remains pending"
  fi
  if [[ -x "$SOURCE_ROOT/build/soong/soong_ui.bash" ]]; then
    result PASS "Soong UI present"
  else
    result WARN "Soong UI not found"
  fi
  if [[ -x "$SOURCE_ROOT/vendor/lineage/build/tasks/kernel.mk" || -f "$SOURCE_ROOT/vendor/lineage/build/tasks/kernel.mk" ]]; then
    result INFO "Lineage kernel build task file exists"
  fi
else
  result INFO "Build dry-run checks require --source"
fi

# Actual VINTF check against an extracted stock/working root.
section "19. Real checkvintf compatibility gate"
if (( RUN_CHECKVINTF == 0 )); then
  result INFO "checkvintf execution disabled"
elif [[ -z "$SOURCE_ROOT" ]]; then
  result INFO "No --source: cannot locate AOSP-built checkvintf reliably"
elif [[ -z "$VINTF_ROOT" ]]; then
  result INFO "No --vintf-root supplied; only static VINTF checks were performed"
  result INFO "For stock/vendor validation, pass --vintf-root pointing to a root containing vendor/, and preferably system/odm/"
else
  if [[ -z "$CV" ]]; then
    result ERROR "--vintf-root supplied but checkvintf is not available"
  elif [[ ! -d "$VINTF_ROOT/vendor" ]]; then
    result ERROR "--vintf-root missing vendor/: $VINTF_ROOT"
  else
    cmd=("$CV" --check-compat --rootdir="$VINTF_ROOT")
    [[ -n "$VINTF_FIRST_API" ]] && cmd+=(--property "ro.product.first_api_level=$VINTF_FIRST_API")
    [[ -n "$VINTF_SKU" ]] && cmd+=(--property "ro.boot.product.hardware.sku=$VINTF_SKU")
    [[ -n "$VINTF_KERNEL" ]] && cmd+=(--kernel "$VINTF_KERNEL")
    result INFO "Running checkvintf --check-compat"
    set +e
    "${cmd[@]}" 2>&1 | tee -a "$REPORT"
    rc=${PIPESTATUS[0]}
    set -e
    if (( rc == 0 )); then result PASS "checkvintf --check-compat passed"; else result ERROR "checkvintf failed (exit $rc) — see report output"; fi
  fi
fi

section "20. Android.mk / Android.bp migration hotspots"
for root in "$TREE" "$VENDOR_TREE" "$KERNEL_TREE"; do
  [[ -n "$root" && -d "$root" ]] || continue
  hits="$(grep_tree "$root" 'LOCAL_(SDK_VERSION|NDK_VERSION|MIN_SDK_VERSION)|LOCAL_MODULE_TAGS|BUILD_HOST_32BIT|TARGET_(SDK|PLATFORM)_VERSION|BOARD_BUILD_SYSTEM_ROOT_IMAGE|BOARD_USES_VENDORIMAGE|BOARD_PROPERTY_OVERRIDES_SPLIT_ENABLED' 160)"
  if [[ -n "$hits" ]]; then
    result WARN "Potential build-system/version hotspots under $root"
    printf '%s\n' "$hits" >> "$REPORT"
    (( QUIET == 0 )) && printf '%s\n' "$hits"
  else
    result PASS "No obvious legacy build-system hotspots under $root"
  fi
done

section "21. Current tree-vs-Lineage requirements summary"
result INFO "LineageOS blob policy: device tree should carry proprietary-files.txt and a reproducible extraction path"
result INFO "LineageOS extraction policy: Lineage 22+ recommends Python extract-utils"
result INFO "LineageOS 24 branch policy: FCM 5 and 6 are outside the current Lineage 24 compatibility window; current examples use FCM 7+"
result INFO "MediaTek stack: hardware/mediatek and device/mediatek sepolicy common trees should be branch-aligned when the device tree depends on them"
result INFO "Vendor blobs: do not 'update' blob versions simply to reach Android 17; validate the stock vendor interface and fix only actual linker/VINTF/HAL incompatibilities"
result INFO "Kernel: keep the hardware kernel unless A17 compatibility checks/build failures prove a kernel-side change is needed"
result INFO "A17 framework: target SDK $TARGET_SDK; framework repo branch should be the ROM's Android 17 branch (for LineageOS, $TARGET_BRANCH)"

section "22. Prioritized migration plan generated from the audit"
result INFO "P0: Ensure the ROM source is truly Android 17 / LineageOS 24 and all manifest-pinned platform repos are on compatible revisions"
result INFO "P0: Establish stock vendor/odm VINTF + vendor SDK/first-API + kernel facts; do not guess"
result INFO "P0: Make device manifest target FCM compatible with the Lineage 24 FCM window; do not merely increment the number"
result INFO "P0: Bring MediaTek common hardware/sepolicy repos to the target branch where available and required"
result INFO "P1: Convert/update proprietary blob extraction to Python extract-utils and regenerate vendor makefiles from the correct stock firmware"
result INFO "P1: Remove VINTF/ABI/property/build suppression flags one at a time and fix the real underlying issue"
result INFO "P1: Reconcile vendor ELF/linker/HAL/AIDL/HIDL issues surfaced by A17 build"
result INFO "P1: Run m nothing -> sepolicy -> boot/vendor/system images -> target-files -> ROM target"
result INFO "P2: Boot Enforcing, then verify VINTF, AVB, radio/audio/camera/graphics/sensors/Wi-Fi/Bluetooth, and OTA"

section "23. Safety gates"
result INFO "SAFE TO EDIT automatically: only mechanical metadata/report generation (this script makes no edits)"
result INFO "NOT SAFE TO auto-edit: FCM target, HAL versions, vendor blobs, kernel config, DTB offsets, partition sizes, sepolicy allows"
result INFO "Do not call a tree 'A17-ready' solely because ninja reaches a successful build; the runtime/vendor/VINTF checks are part of readiness"

section "24. Summary"
say "PASS=$PASS  WARN=$WARN  ERROR=$ERR  INFO=$INFO"
if (( ERR == 0 && WARN == 0 )); then
  result PASS "No obvious blockers detected by this audit"
elif (( ERR == 0 )); then
  result WARN "No fatal static errors detected, but warnings remain; review before calling the stack A17-ready"
else
  result ERROR "Audit found $ERR error(s); fix/understand them before flashing"
fi
say ""
say "Report saved to: $REPORT"
say "This script made NO source-tree modifications."

if (( STRICT == 1 && WARN > 0 )); then exit 1; fi
(( ERR > 0 )) && exit 1
exit 0
