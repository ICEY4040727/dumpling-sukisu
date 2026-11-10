#!/usr/bin/env bash
# Build a SukiSU-Ultra kernel for OnePlus 5 / 5T (cheeseburger / dumpling)
# Target: LineageOS 22.2 (Android 15), kernel 4.4.302, non-GKI, non-slot boot.
#
# Usage (Linux / WSL2 / GitHub Actions ubuntu-22.04):
#   ./build.sh prepare     download sources + toolchains, integrate SukiSU, write defconfig, self-check
#   ./build.sh build       compile (requires prepare)
#   ./build.sh pack        produce the AnyKernel3 flashable zip (requires build)
#   ./build.sh all         all of the above
#   ./build.sh hooks       print the 4.4 manual-hook sites (preview / teaching)
#   ./build.sh clean       remove work/ but keep out/
#
# Override the SukiSU branch. The workflow passes its input via env;
# toolchain.conf holds the fallback default (builtin, matching the workflow).
#   SUKISU_REF=builtin ./build.sh all     full 4.4 compat layer; hooks inserted below
#   SUKISU_REF=old     ./build.sh all     kprobes + generated 4.4 compat shims
#   SUKISU_REF=main    ./build.sh all     proven broken on 4.4 (Run #1)
# The repo itself is overridable too, for the KernelSU-Next experiment
# (never compiled here; its 4.4 support is unverified):
#   SUKISU_REPO=https://github.com/pershoot/KernelSU-Next.git SUKISU_REF=next-susfs ./build.sh all
#
# IMPORTANT / honest scope:
#   Every URL, hash, defconfig name, build command and AK3 property in this
#   script was read from upstream source files on 2026-11-08 (see toolchain.conf).
#   Authored on a Windows host with no Linux kernel toolchain; the real build
#   runs on the GitHub Actions ubuntu-22.04 runner.
#   As of Run #8 (2026-11-10) the full pipeline compiles and produces an
#   AnyKernel3 zip; flashing it on a real dumpling was verified end to end:
#   /proc/version shows the new banner, dmesg shows the KSU driver init,
#   and `su -c id` returns uid=0 with context u:r:ksu:s0 (README 5.12).
#   KPM, cpu_spoof and SUSFS are NOT in this build (4.4 has no support;
#   see gate_optional_features).
#
# Safety before flashing:
#   - Unlocked bootloader, TWRP for cheeseburger/dumpling installed.
#   - Back up your current boot.img. It is your one-step rollback.
#   - This is a non-A/B device: BLOCK=/dev/block/bootdevice/by-name/boot.
#   - After flashing the AK3 zip, install the SukiSU-Ultra Manager APK from
#     https://github.com/SukiSU-Ultra/SukiSU-Ultra/releases

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=toolchain.conf
source "$ROOT/toolchain.conf"

WORK="${WORK:-$ROOT/work}"
OUT="$ROOT/out"
KDIR="$WORK/android_kernel_oneplus_msm8998-$KERNEL_HASH"
AK3="$WORK/AnyKernel3-$ANYKERNEL_HASH"
STAGE="${1:-all}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\n[FAIL] %s\n' "$*" >&2; exit 1; }

# Product tag used in output file names and log lines. Derived from the repo
# URL, so switching to another KSU fork cannot leave a "SukiSU" label on a
# KernelSU-Next build. The historical spelling is kept for the default repo.
ksu_product_tag() {
  local base="${SUKISU_REPO##*/}"
  base="${base%.git}"
  case "$base" in
    SukiSU-Ultra|SukiSU) echo "SukiSU" ;;
    KernelSU-Next)       echo "KernelSU-Next" ;;
    "")                  echo "KSU" ;;
    *)                   echo "$base" ;;
  esac
}

case "$(uname -s)" in
  Linux*) ;;
  *) die "A Linux build host is required (ubuntu-22.04 or WSL2). Current: $(uname -s)" ;;
esac

fetch() {
  local url="$1" dst="$2"
  if [ -s "$dst" ]; then echo "  cached   $(basename "$dst")"; return 0; fi
  echo "  download $(basename "$dst")"
  wget -c -q -O "$dst" "$url" || die "download failed: $url"
}

download_all() {
  log "Fetching sources and toolchains into $WORK"
  mkdir -p "$WORK" "$OUT"
  fetch "$KERNEL_URL"      "$WORK/kernel.zip"
  fetch "$LLVM_URL"        "$WORK/clang.tar.gz"
  fetch "$AARCH64_GCC_URL" "$WORK/aarch64-gcc.zip"
  fetch "$ARM_GCC_URL"     "$WORK/arm-gcc.zip"
  fetch "$PREBUILTS_URL"   "$WORK/prebuilts.zip"
  fetch "$ANYKERNEL_URL"   "$WORK/anykernel3.zip"

  [ -d "$KDIR" ] || unzip -q "$WORK/kernel.zip" -d "$WORK"
  [ -d "$WORK/$LLVM_TAG/bin" ] || { mkdir -p "$WORK/$LLVM_TAG"; tar -zxf "$WORK/clang.tar.gz" -C "$WORK/$LLVM_TAG"; }
  [ -d "$WORK/AnyKernel3-$ANYKERNEL_HASH" ] || unzip -q "$WORK/anykernel3.zip" -d "$WORK"
  for z in aarch64-gcc arm-gcc prebuilts; do unzip -q -o "$WORK/$z.zip" -d "$WORK"; done

  # The GCC 4.9 wrappers call /usr/bin/python with python2 syntax (upstream ci.sh does the same).
  if [ ! -e /usr/bin/python ] && command -v python2 >/dev/null 2>&1; then
    sudo ln -s "$(command -v python2)" /usr/bin/python 2>/dev/null || true
  fi
  [ -d "$KDIR" ] || die "kernel tree missing after unpack: $KDIR"
}

integrate_sukisu() {
  log "Integrating $(ksu_product_tag) ($SUKISU_REF) into the kernel tree"
  local ksu="$KDIR/KernelSU"
  if [ ! -d "$ksu/.git" ]; then
    git clone --depth 1 -b "$SUKISU_REF" "$SUKISU_REPO" "$ksu" \
      || die "git clone failed for branch '$SUKISU_REF'"
  else
    echo "  existing checkout: $(git -C "$ksu" rev-parse --abbrev-ref HEAD)"
  fi

  # Same three edits as the official kernel/setup.sh, done explicitly so
  # nothing is fetched-and-executed sight unseen (no curl | bash).
  ln -sfn "../KernelSU/kernel" "$KDIR/drivers/kernelsu"
  grep -q 'CONFIG_KSU.*kernelsu/' "$KDIR/drivers/Makefile" \
    || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$KDIR/drivers/Makefile"
  # Verified: drivers/Kconfig on lineage-22.2 contains exactly one "endmenu".
  grep -q 'drivers/kernelsu/Kconfig' "$KDIR/drivers/Kconfig" \
    || sed -i '/^endmenu/i\source "drivers/kernelsu/Kconfig"' "$KDIR/drivers/Kconfig"
}

apply_compat_patches() {
  log "Applying 4.4 compatibility shims to SukiSU sources"
  local ksu="$KDIR/KernelSU/kernel"
  [ -d "$ksu" ] || die "SukiSU kernel dir missing: $ksu"

  # Three 5.x-era APIs that 4.4 does not have, all confirmed against raw
  # sources (see README 5.4). The shims are lifted from SukiSU's own
  # builtin/kernel/kernel_compat.h, which is the branch that actually ships
  # a complete <4.14 compatibility layer; "old" ships almost none.
  #
  #  1. MODULE_IMPORT_NS()   - 5.4+. 4.4 has no module symbol namespaces, so
  #     neutralising the call is a semantic no-op.
  #  2. TWA_RESUME           - 5.7+ enum / v5.9 #define 1. 4.4's
  #     task_work_add(task, work, bool notify) takes a bool; 1 == true is the
  #     exact semantic equivalent of TWA_RESUME.
  #  3. kernel_read/write    - 4.4 declares
  #     kernel_write(file*, const char*, size_t, loff_t)   [offset by value]
  #     kernel_read(file*, loff_t, char*, unsigned long)   [different order]
  #     KernelSU calls the 5.x form (buf, count, loff_t *). vfs_read/write
  #     take loff_t * and advance it, which is what the caller expects.
  #
  # A separate header is used instead of appending to kernel/kernel_compat.h:
  # on the "old" branch that file calls copy_from_user_nofault(), which is
  # itself 5.8+, so including it wholesale would create a new failure.
  python3 - "$ksu" <<'PY'
import os, sys, re
root = sys.argv[1]
hdr = os.path.join(root, "ksu_44_compat.h")

# The 'builtin' branch ships a complete <4.14 layer in its own kernel_compat.h:
# ksu_kernel_read_compat / ksu_kernel_write_compat (non-static definitions),
# TWA_RESUME, kvmalloc, strscpy, close_fd, groups_sort. ksu_main.c is a unity
# build that includes that header before every .c. Injecting OUR header -- whose
# shims are static inline but have the SAME names -- into those .c files would
# be a redefinition error in that single translation unit. Detect and skip.
own = os.path.join(root, "kernel_compat.h")
has_own_shims = False
if os.path.isfile(own):
    with open(own, encoding="utf-8", errors="replace") as f:
        t = f.read()
    has_own_shims = ("define TWA_RESUME" in t) and ("define kernel_read" in t)

COMPAT = r'''/* 4.4 compatibility shims for SukiSU-Ultra (generated by build.sh). */
#ifndef __KSU_44_COMPAT_H
#define __KSU_44_COMPAT_H

#include <linux/compiler.h>
#include <linux/fs.h>
#include <linux/gfp.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/version.h>
#include <linux/vmalloc.h>

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 7, 0)
#ifndef TWA_RESUME
#define TWA_RESUME 1
#endif
#endif

#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 14, 0)
static inline ssize_t ksu_kernel_read_compat(struct file *p, void *buf,
                                             size_t count, loff_t *pos)
{
    mm_segment_t old_fs;
    ssize_t res;
    old_fs = get_fs();
    set_fs(get_ds());
    res = vfs_read(p, (void __user *)buf, count, pos);
    set_fs(old_fs);
    return res;
}

static inline ssize_t ksu_kernel_write_compat(struct file *p, const void *buf,
                                              size_t count, loff_t *pos)
{
    mm_segment_t old_fs;
    ssize_t res;
    old_fs = get_fs();
    set_fs(get_ds());
    res = vfs_write(p, (__force const char __user *)buf, count, pos);
    set_fs(old_fs);
    return res;
}

#define kernel_read ksu_kernel_read_compat
#define kernel_write ksu_kernel_write_compat
#endif

#endif
'''
with open(hdr, "w", encoding="utf-8", newline="\n") as f:
    f.write(COMPAT)

api = re.compile(r'\b(TWA_RESUME|kernel_read|kernel_write)\s*\(')
ns_count = inc_count = 0
for dirpath, _, files in os.walk(root):
    for fn in files:
        if not fn.endswith(".c"):
            continue
        p = os.path.join(dirpath, fn)
        text = open(p, encoding="utf-8", errors="replace").read()
        lines = text.splitlines(True)

        out, changed = [], False
        for line in lines:
            stripped = line.lstrip()
            if stripped.startswith("MODULE_IMPORT_NS(") and not stripped.startswith("/*"):
                out.append(line[: len(line) - len(stripped)]
                           + "/* 4.4: no module symbol namespaces; call omitted */\n")
                changed = True
                ns_count += 1
            else:
                out.append(line)
        if changed:
            lines = out

        if not has_own_shims and "ksu_44_compat.h" not in text and api.search(text):
            last = None
            for i, line in enumerate(lines[:80]):
                if line.lstrip().startswith("#include"):
                    last = i + 1
            if last is not None:
                rel = os.path.relpath(hdr, dirpath).replace(os.sep, "/")
                lines.insert(last, '#include "%s"\n' % rel)
                inc_count += 1
                changed = True

        if changed:
            with open(p, "w", encoding="utf-8", newline="") as f:
                f.writelines(lines)

print("  MODULE_IMPORT_NS calls neutralised: %d" % ns_count)
if has_own_shims:
    print("  builtin kernel_compat.h already provides 4.4 shims; injection skipped")
else:
    print("  compat header injected into %d source files" % inc_count)
PY
  echo "  Known 4.4 gaps handled. Further compile errors may still appear;"
  echo "  fix them one round at a time (see README section 5)."
}

gate_cpu_spoof() {
  log "Disabling the CPU-spoof extension on 4.4 (vDSO layout differs)"

  # Run #6: extension/cpu_spoof.c:29 wants <vdso/datapage.h>, absent on 4.4.
  # A shim header would NOT be enough. The same file then uses
  #   struct vdso_time_data / struct vdso_data.clock_mode /
  #   struct clocksource.vdso_clock_mode / enum vdso_clock_mode
  # none of which exist on 4.4. Verified against the pinned tree:
  #   arch/arm64/include/asm/vdso_datapage.h:38 struct vdso_data has
  #     cs_cycle_last / xtime_clock_sec / ... and NO clock_mode field.
  #   include/linux/clocksource.h has 0 occurrences of vdso_clock_mode.
  # Worse, 4.4 arm64 DOES export a real "vdso_data" symbol. Faking a 5.x
  # struct would make the kallsyms lookup succeed and then write 5.x-layout
  # fields into real 4.4 memory -- a plausible kernel panic.
  #
  # cpu_spoof is an optional io-only extension (spoof MIDR/bogomips/hwcap),
  # not part of the root path: extension.c only registers its ioctl handler.
  # On 4.4 we keep that symbol, return -EOPNOTSUPP, and let the preprocessor
  # skip the whole incompatible body through #if / #else / #endif.
  python3 - "$KDIR/KernelSU/kernel" <<'PY'
import os, sys

KSU = sys.argv[1]
MARK = "dumpling-sukisu: 4.4 cpu_spoof stub"
p = os.path.join(KSU, "extension", "cpu_spoof.c")
if not os.path.isfile(p):
    print("  no cpu_spoof.c on this branch; feature gate skipped")
    sys.exit(0)
with open(p, encoding="utf-8", errors="replace") as f:
    t = f.read()
if MARK in t:
    if not t.rstrip().endswith("#endif /* " + MARK + " */"):
        sys.exit("  [FAIL] cpu_spoof.c: stub marker present but closing #endif missing")
    print("  already gated: extension/cpu_spoof.c")
    sys.exit(0)
anchor = "#include <linux/version.h>"
i = t.find(anchor)
if i < 0:
    sys.exit("  [FAIL] cpu_spoof.c: '#include <linux/version.h>' anchor not found")
pos = i + len(anchor)
stub = (
    f"\n\n#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 4, 0)\n"
    f"/* {MARK}: 4.4 has a different vDSO layout; see build.sh. */\n"
    "int ksu_extension_cpu_spoof_io(u32 id, void __user *raw)\n"
    "{\n"
    "    (void)id;\n"
    "    (void)raw;\n"
    "    return -EOPNOTSUPP;\n"
    "}\n"
    "#else\n"
)
t = t[:pos] + stub + t[pos:] + "\n#endif /* " + MARK + " */\n"
with open(p, "w", encoding="utf-8", newline="") as f:
    f.write(t)
print("  gated: extension/cpu_spoof.c (4.4 ioctl returns -EOPNOTSUPP)")
PY
}

gate_optional_features() {
  log "Wiring the upstream KPM/SUSFS switches into the unity build"

  # Run #7 produced five errors that look unrelated but share one cause:
  # SukiSU's Kconfig has CONFIG_KPM / CONFIG_KSU_SUSFS, but the Makefile only
  # prints them ($(info -- KPM is disabled)) and ksu_main.c #includes EVERY
  # .c unconditionally into one translation unit. Turning the options off in
  # the defconfig therefore changes nothing at compile time.
  #
  # Verified against builtin HEAD 1cfa573 and pinned 4.4 commit 9932c9e...:
  #   kpm/kpm.c:182            access_ok(addr, size)  -- 4.4 needs 3 args
  #                            (arch/arm64/include/asm/uaccess.h:134)
  #   kpm/super_access.c:171   DEFINE_MEMBER(task_struct, security) -- 4.4
  #                            sched.h has NO security field; CONFIG_SECURITY=y
  #                            in lineage_oneplus5_defconfig makes it expand
  #   kpm/super_access.c:175   sizeof on an incomplete array -- downstream of
  #                            the failed DEFINE_MEMBER above, not a 4th bug
  #   manager/pkg_observer.c:24,37  susfs_parse_priority_app_strings() has
  #                            ZERO definitions in the whole branch (it comes
  #                            from the external susfs4ksu patch)
  #   supercall/dispatch.c:622     kvcalloc() -- absent on 4.4; the branch's
  #                            own kernel_compat.h already shims kvmalloc,
  #                            kvmalloc_array and kvfree but forgot kvcalloc
  #
  # KPM is safe to drop: a full-tree symbol scan shows its only external
  # references are the kpm_handler definition/registration in extension.c
  # (the .h files merely declare externs). No root-path code calls it.
  # The SUSFS call is a priority-uid bitmap refresh; skipping it leaves the
  # throne tracker intact.
  python3 - "$KDIR/KernelSU/kernel" <<'PY'
import os, sys

KSU = sys.argv[1]
MARK_KPM = "dumpling-sukisu: 4.4 KPM gate"
MARK_SUSFS = "dumpling-sukisu: 4.4 SUSFS gate"
MARK_KV = "dumpling-sukisu: 4.4 kvcalloc shim"

def fail(msg):
    sys.exit("  [FAIL] " + msg)

def load(rel):
    p = os.path.join(KSU, rel)
    if not os.path.isfile(p):
        return None, None
    with open(p, encoding="utf-8", errors="replace") as f:
        return p, f.read()

def save(p, t):
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.write(t)

changed = 0

# ---- 1. ksu_main.c: put the four KPM unity includes behind CONFIG_KPM ----
p, t = load("ksu_main.c")
if p is not None:
    block = ('#include "extension/kpm.c"\n'
             '#include "extension/kpm/kpm.c"\n'
             '#include "extension/kpm/compact.c"\n'
             '#include "extension/kpm/super_access.c"\n')
    gated = ("#ifdef CONFIG_KPM /* " + MARK_KPM + " */\n" + block +
             "#endif /* CONFIG_KPM */\n")
    if MARK_KPM in t:
        if gated not in t:
            fail("ksu_main.c: marker present but the KPM gate block is malformed")
        print("  already gated: ksu_main.c (KPM unity includes)")
    elif block in t:
        save(p, t.replace(block, gated, 1))
        changed += 1
        print("  gated: ksu_main.c (4 KPM unity includes behind CONFIG_KPM)")
    else:
        fail("ksu_main.c: the 4 KPM unity includes were not found verbatim")

# ---- 2. extension.c: gate the handler definition and its registration ----
p, t = load(os.path.join("extension", "extension.c"))
if p is not None:
    if MARK_KPM in t:
        if t.count(MARK_KPM) != 2:
            fail("extension/extension.c: expected 2 KPM markers, found %d" % t.count(MARK_KPM))
        print("  already gated: extension/extension.c (KPM handler)")
    else:
        lines = t.splitlines(True)
        def find(pred, start=0):
            return next((i for i in range(start, len(lines)) if pred(lines[i])), None)
        si = find(lambda l: "static const struct ksu_extension_handler kpm_handler = {" in l)
        if si is None:
            fail("extension/extension.c: kpm_handler definition not found")
        ei = find(lambda l: l.strip() == "};", si + 1)
        if ei is None:
            fail("extension/extension.c: end of kpm_handler not found")
        ri = find(lambda l: "ksu_register_extension_handler(&kpm_handler)" in l)
        if ri is None:
            fail("extension/extension.c: kpm_handler registration not found")
        if ri + 1 >= len(lines) or "failed to register kpm" not in lines[ri + 1]:
            fail("extension/extension.c: kpm registration pr_err line moved")
        opens = "#ifdef CONFIG_KPM /* " + MARK_KPM + " */\n"
        closes = "#endif /* CONFIG_KPM */\n"
        for idx, text in sorted([(ri + 2, closes), (ri, opens),
                                 (ei + 1, closes), (si, opens)], reverse=True):
            lines[idx:idx] = [text]
        save(p, "".join(lines))
        changed += 1
        print("  gated: extension/extension.c (KPM handler + registration)")

# ---- 3. pkg_observer.c: gate the two external-SUSFS calls ----
p, t = load(os.path.join("manager", "pkg_observer.c"))
if p is not None:
    if MARK_SUSFS in t:
        print("  already gated: manager/pkg_observer.c (SUSFS calls)")
    else:
        lines = t.splitlines(True)
        hits = [i for i, l in enumerate(lines)
                if l.strip() == "susfs_parse_priority_app_strings();"]
        if len(hits) != 2:
            fail("pkg_observer.c: expected 2 susfs_parse_priority_app_strings() calls, found %d" % len(hits))
        for i in reversed(hits):
            lines[i:i+1] = ["#ifdef CONFIG_KSU_SUSFS /* " + MARK_SUSFS + " */\n",
                            lines[i],
                            "#endif /* CONFIG_KSU_SUSFS */\n"]
        save(p, "".join(lines))
        changed += 1
        print("  gated: manager/pkg_observer.c (2 external SUSFS calls)")

# ---- 4. kernel_compat.h: finish the kvmalloc family with kvcalloc ----
p, t = load("kernel_compat.h")
if p is not None:
    if MARK_KV in t:
        print("  already shimmed: kernel_compat.h (kvcalloc)")
    else:
        anchor = "#define kvfree ksu_kvfree\n"
        if anchor not in t:
            fail("kernel_compat.h: '#define kvfree ksu_kvfree' anchor not found")
        shim = (anchor + "\n/* " + MARK_KV + " */\n"
                "#ifndef kvcalloc\n"
                "static inline void *ksu_kvcalloc(size_t n, size_t size, gfp_t flags)\n"
                "{\n"
                "    size_t total;\n"
                "    void *buf;\n"
                "    if (size && n > ((size_t)-1) / size)\n"
                "        return NULL;\n"
                "    total = n * size;\n"
                "    buf = kzalloc(total, flags);\n"
                "    if (!buf)\n"
                "        buf = vzalloc(total);\n"
                "    return buf;\n"
                "}\n"
                "#define kvcalloc ksu_kvcalloc\n"
                "#endif\n")
        save(p, t.replace(anchor, shim, 1))
        changed += 1
        print("  shimmed: kernel_compat.h (kvcalloc -> kzalloc/vzalloc)")

print("  feature gates changed %d files" % changed)
PY
}

apply_header_gates() {
  log "Gating headers that do not exist in the 4.4 tree"

  # Run #5: compiling builtin on 4.4 died at kernel_includes.h:76 with
  #   fatal error: 'linux/static_call.h' file not found
  # The other 75 includes in that file all resolved, which rules out the
  # whole "uapi aliases / generated headers" family of false positives.
  #
  # Evidence, pinned commit 9932c9e... (57109 blobs) vs builtin HEAD 1cfa573:
  #   linux/static_call.h        absent, unconditional, kernel_includes.h:76
  #   linux/sched/signal.h       absent, unconditional, infra/symbol_resolver.c:5
  #   linux/set_memory.h         absent, unconditional, kpm/compact.c:23
  #                                                     kpm/super_access.c:23
  # All four .c/.h files are in ksu_main.c's unity translation unit. None of
  # them use a single symbol from those headers (grep over the full branch:
  # no static_call(), no set_memory_*(), no sched/signal-only type). The
  # upstream file already gates the same sched/*.h headers behind >= 4.10,
  # and compiler_types.h behind >= 4.14, so gating is the author's own idiom.
  #
  # We comment the four lines out rather than inventing a KERNEL_VERSION
  # threshold we cannot verify. This build script targets 4.4 only.
  python3 - "$KDIR" "$KDIR/KernelSU/kernel" <<'PY'
import os, re, sys

KDIR, KSU = sys.argv[1], sys.argv[2]
MARK = "dumpling-sukisu: 4.4 header gate"

# The workflow still exposes old / main / builtin-new as inputs. Those trees
# do not all have this layout; do not fail an unrelated branch on a missing
# file. If kernel_includes.h exists, the four gate targets must exist too.
if not os.path.isfile(os.path.join(KSU, "kernel_includes.h")):
    print("  no kernel_includes.h on this branch; header gates skipped")
    sys.exit(0)

GATES = [
    ("kernel_includes.h", "#include <linux/static_call.h>",
     "static_call is 5.10+; builtin never calls static_call()"),
    ("infra/symbol_resolver.c", "#include <linux/sched/signal.h>",
     "sched/signal.h is 4.10+; kernel_includes.h already gates it there"),
    ("extension/kpm/compact.c", "#include <linux/set_memory.h>",
     "linux/set_memory.h is absent on 4.4; no set_memory_* symbol used"),
    ("extension/kpm/super_access.c", "#include <linux/set_memory.h>",
     "linux/set_memory.h is absent on 4.4; no set_memory_* symbol used"),
]

for rel, inc, why in GATES:
    p = os.path.join(KSU, rel)
    if not os.path.isfile(p):
        sys.exit("  [FAIL] %s: file not found" % rel)
    with open(p, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines(True)
    hits = [i for i, l in enumerate(lines) if l.strip() == inc]
    if any(MARK in l for l in lines):
        if hits:
            sys.exit("  [FAIL] %s: marker present but %s still live" % (rel, inc))
        print("  already gated: %s" % rel)
        continue
    if not hits:
        print("  WARN  %s: %s not found (upstream may have fixed it)" % (rel, inc))
        continue
    i = hits[0]
    lines[i:i + 1] = [
        "/* %s (%s) */\n" % (MARK, rel),
        "/* %s */\n" % why,
        "/* 4.4: %s */\n" % inc,
    ]
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.writelines(lines)
    print("  gated: %s (%s)" % (rel, inc))

# ---- Preflight -----------------------------------------------------------
# Run #6: the old version had two blind spots. It only looked at a hard-coded
# prefix list, so <vdso/datapage.h> was never checked at all; and it assumed
# EVERY #if block was inactive on 4.4, so an include behind
# "#if defined(CONFIG_ARM64)" was skipped even though ARM64 is exactly our
# target. Now: scan every angle-bracket include and evaluate the condition
# stack with real 4.4 / arm64 values, including #elif and #else.
# Still diagnostic only -- a false positive must never abort prepare.
GENERATED = {"generated/compile.h", "generated/utsrelease.h", "linux/version.h"}
LINUX = (4 << 16) | (4 << 8) | 302          # 4.4.302
TRUE = {"CONFIG_ARM64", "__aarch64__", "CONFIG_64BIT", "CONFIG_KSU",
        "CONFIG_KPROBES", "CONFIG_SMP", "CONFIG_MODULES"}

def cond(expr):
    e = expr.strip()
    e = re.sub(r"KERNEL_VERSION\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)",
               lambda m: str((int(m.group(1)) << 16) | (int(m.group(2)) << 8)
                             | int(m.group(3))), e)
    e = e.replace("LINUX_VERSION_CODE", str(LINUX))
    e = re.sub(r"defined\s*\(\s*([A-Za-z_]\w*)\s*\)|defined\s+([A-Za-z_]\w*)",
               lambda m: "1" if (m.group(1) or m.group(2)) in TRUE else "0", e)
    e = re.sub(r"\b[A-Z_][A-Z0-9_]*\b", "0", e)
    e = e.replace("&&", " and ").replace("||", " or ")
    e = re.sub(r"!(?!=)", " not ", e)
    try:
        return bool(eval(e, {"__builtins__": {}}, {}))
    except Exception:
        return True       # unknown expression: assume active so it is reported

def resolvable(inc):
    cands = [
        "include/" + inc,
        "include/uapi/" + inc,
        "include/generated/" + inc,
        "include/generated/uapi/" + inc,
        "arch/arm64/include/" + inc,
        "arch/arm64/include/uapi/" + inc,
        "arch/arm64/include/generated/" + inc,
        "arch/arm64/include/generated/uapi/" + inc,
        # ccflags-y -Isecurity/selinux{,/include} resolves <security.h>, <ss/*>
        "security/selinux/" + inc,
        "security/selinux/include/" + inc,
        # <../fs/mount.h> resolves through -Iinclude -> include/../fs/mount.h
        os.path.normpath("include/" + inc),
    ]
    return any(os.path.isfile(os.path.join(KDIR, c)) for c in cands)

def scan(path):
    """Yield (include, line) for includes that 4.4/arm64 would actually preprocess."""
    if not os.path.isfile(path):
        return
    stack = []
    for n, raw in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
        s = raw.strip()
        parent = stack[-1]["taken"] if stack else True
        m = re.match(r"#\s*(ifdef|ifndef|if)\s+(.*)", s)
        if m:
            kind, expr = m.group(1), m.group(2)
            t = (expr.strip() in TRUE) if kind == "ifdef" else \
                (expr.strip() not in TRUE) if kind == "ifndef" else cond(expr)
            t = parent and t
            stack.append({"parent": parent, "taken": t, "any": t})
            continue
        m = re.match(r"#\s*elif\s+(.*)", s)
        if m and stack:
            it = stack[-1]
            it["taken"] = it["parent"] and (not it["any"]) and cond(m.group(1))
            it["any"] = it["any"] or it["taken"]
            continue
        if re.match(r"#\s*else\b", s) and stack:
            it = stack[-1]
            it["taken"] = it["parent"] and (not it["any"])
            it["any"] = True
            continue
        if re.match(r"#\s*endif\b", s):
            if stack: stack.pop()
            continue
        if all(x["taken"] for x in stack):
            mm = re.match(r"#include\s*<([^>]+)>", s)
            if mm:
                yield mm.group(1), n

main = os.path.join(KSU, "ksu_main.c")
units = ["kernel_includes.h", "kernel_compat.h"]
if os.path.isfile(main):
    units += re.findall(r'#include\s*"([^"]+\.c)"',
                        open(main, encoding="utf-8", errors="replace").read())
seen, gaps = set(), []
for rel in units:
    for inc, n in scan(os.path.join(KSU, rel)):
        seen.add(inc)
        if inc not in GENERATED and not resolvable(inc):
            gaps.append("%s (%s:%d)" % (inc, rel, n))
print("  preflight: %d distinct active system includes in unity TU" % len(seen))
for g in sorted(set(gaps)):
    print("  WARN  unresolvable on 4.4: %s" % g)
if not gaps:
    print("  OK  no active header gaps left")
PY
}

apply_manual_hooks() {
  [ "$SUKISU_REF" = "builtin" ] || return 0
  log "Inserting manual hooks for SUKISU_REF=builtin into the 4.4 tree"

  # builtin registers no kprobes: these calls ARE the driver's entry points.
  # Without them the kernel would link fine but SukiSU would never fire.
  #
  # Verified against the pinned lineage-22.2 tree (commit 9932c9e...) and
  # against builtin HEAD 1cfa573: see README 5.6 for the raw line numbers.
  # All four extern signatures match the non-SUSFS branch used by our
  # defconfig (CONFIG_KSU_SUSFS is not set).
  #
  # Run #4 lesson: fs/open.c's first statement is
  #     if (mode & ~S_IRWXO)	/* where's F_OK, X_OK, W_OK, R_OK? */
  # The old code compared the full stripped line with ==, so the trailing
  # comment made the anchor miss. Anchors are now matched by prefix, tried
  # in order, and a miss dumps the real source instead of dying silently.
  python3 - "$KDIR" <<'PY'
import os, sys

KDIR = sys.argv[1]
MARK = "dumpling-sukisu: manual hook"

# (file, function anchors, insert anchors, hook body)
# Several candidates per site: a future backport may rename one line without
# changing the others. The earliest matching line wins.
SITES = [
    ("fs/exec.c",
     ["static int do_execveat_common("],
     ["if (IS_ERR(filename))"],
     ["#ifdef CONFIG_KSU",
      "/* " + MARK + " (4.4.302 / non-GKI) */",
      "extern int ksu_handle_execveat(int *, struct filename **, void *, void *, int *);",
      "ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);",
      "#endif"]),
    ("fs/open.c",
     ["SYSCALL_DEFINE3(faccessat,"],
     ["if (mode & ~S_IRWXO)", "override_cred = prepare_creds();"],
     ["#ifdef CONFIG_KSU",
      "/* " + MARK + " (4.4.302 / non-GKI) */",
      "extern int ksu_handle_faccessat(int *, const char __user **, int *, int *);",
      "ksu_handle_faccessat(&dfd, &filename, &mode, NULL);",
      "#endif"]),
    ("fs/stat.c",
     ["SYSCALL_DEFINE4(newfstatat,"],
     ["error = vfs_fstatat(dfd, filename, &stat, flag);"],
     ["#ifdef CONFIG_KSU",
      "/* " + MARK + " (4.4.302 / non-GKI) */",
      "extern int ksu_handle_stat(int *, const char __user **, int *);",
      "ksu_handle_stat(&dfd, &filename, &flag);",
      "#endif"]),
    ("kernel/reboot.c",
     ["SYSCALL_DEFINE4(reboot,"],
     ["if (!ns_capable(pid_ns->user_ns, CAP_SYS_BOOT))"],
     ["#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_KSUD)",
      "/* " + MARK + " (4.4.302 / non-GKI) */",
      "extern int ksu_handle_sys_reboot(int, int, unsigned int, void __user **);",
      "ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);",
      "#endif"]),
]

# 4.4 is C89-style: a statement inserted before local declarations fails to
# compile. A hook may therefore only be placed at the first statement of the
# function, so everything between "{" and the anchor must be a declaration,
# a comment, a preprocessor line or blank.
DECL_STARTS = ("const ", "struct ", "union ", "enum ", "unsigned ", "signed ",
               "int ", "long ", "short ", "char ", "void ", "bool ", "static ",
               "extern ", "loff_t ", "size_t ", "ssize_t ", "u8 ", "u16 ",
               "u32 ", "u64 ", "s32 ", "s64 ", "atomic_t ")


def decl_or_ignorable(s):
    s = s.strip()
    if not s or s.startswith(("/*", "*", "//", "#")):
        return True
    if s.startswith(DECL_STARTS):
        return True
    # continuation line of a multi-line declaration
    return not s.endswith((";", "{", "}")) and "(" not in s


def dump_source(rel, lines, si, count=40):
    print("  --- %s: real source starting at line %d ---" % (rel, si + 1))
    for j in range(si, min(si + count, len(lines))):
        print("  %5d| %s" % (j + 1, lines[j].rstrip("\n")))
    print("  --- end of dump ---")


for rel, starts, anchors, body in SITES:
    p = os.path.join(KDIR, rel)
    if not os.path.isfile(p):
        sys.exit("  [FAIL] %s: file not found" % rel)
    with open(p, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines(True)
    if any(MARK in l for l in lines):
        print("  already hooked: %s" % rel)
        continue

    si = next((i for i, l in enumerate(lines) if any(s in l for s in starts)), None)
    if si is None:
        sys.exit("  [FAIL] %s: no function anchor in %r" % (rel, starts))
    brace = next((i for i in range(si, min(si + 12, len(lines)))
                  if lines[i].strip() == "{"), None)
    if brace is None:
        dump_source(rel, lines, si)
        sys.exit("  [FAIL] %s: opening brace not found after function anchor" % rel)

    bi, matched = None, None
    for i in range(brace + 1, min(si + 80, len(lines))):
        for a in anchors:
            if lines[i].strip().startswith(a):
                bi, matched = i, a
                break
        if bi is not None:
            break
    if bi is None:
        dump_source(rel, lines, si)
        sys.exit("  [FAIL] %s: no insert anchor from %r within 80 lines"
                 % (rel, anchors))

    for j in range(brace + 1, bi):
        if not decl_or_ignorable(lines[j]):
            dump_source(rel, lines, si)
            sys.exit("  [FAIL] %s: line %d is a statement, hook would land after "
                     "it and break C89 declaration order: %s"
                     % (rel, j + 1, lines[j].strip()))

    indent = lines[bi][:len(lines[bi]) - len(lines[bi].lstrip())]
    block = [(l + "\n") if l.startswith("#") else (indent + l + "\n") for l in body]
    lines[bi:bi] = block
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.writelines(lines)
    print("  hooked: %s (before %r)" % (rel, matched))
PY
}

configure_defconfig() {
  log "Writing required CONFIG entries to $DEFCONFIG"
  python3 - "$KDIR/arch/arm64/configs/$DEFCONFIG" <<'PY'
import sys
p = sys.argv[1]
keys = [
    "CONFIG_KSU", "CONFIG_KPM", "CONFIG_KSU_SUSFS",
    "CONFIG_KALLSYMS", "CONFIG_KALLSYMS_ALL",
    "CONFIG_KPROBES", "CONFIG_KRETPROBES",
    "CONFIG_CC_WERROR",
]
lines = open(p).read().splitlines()
def owned(l):
    s = l.lstrip("# ").strip()
    return any(s == k + "=y" or s == k + "=m" or s == k + "=n"
               or s == k + " is not set" or l.startswith(k + "=") for k in keys)
lines = [l for l in lines if not owned(l)]
lines += [
    "",
    "# --- SukiSU-Ultra (dumpling / 4.4.302) ---",
    "CONFIG_KSU=y",
    "CONFIG_KALLSYMS=y",
    "CONFIG_KALLSYMS_ALL=y",
    "CONFIG_KPROBES=y",
    "CONFIG_KRETPROBES=y",
    "# CONFIG_KPM is not set",
    "# CONFIG_KSU_SUSFS is not set",
    "# CONFIG_CC_WERROR is not set",
    "# --- end SukiSU-Ultra ---",
]
open(p, "w").write("\n".join(lines) + "\n")
PY
  echo "  KPM off: arch/arm64/include/asm/set_memory.h does not exist on 4.4 (verified)."
  echo "  SUSFS off: builtin Kconfig gates it on THREAD_INFO_IN_TASK, absent on 4.4."
  echo "  CC_WERROR off: old 4.4 tree + clang-r547379 produces warnings; do not fail the build on them."
}

show_hooks() {
  log "Manual hook sites for SUKISU_REF=builtin (4.4.302)"
  echo "  These are printed from YOUR kernel tree, not from a generic template."
  echo "  The official guide: https://sukisu.org/guide/how-to-integrate"
  echo "  4.4 buckets: execve -> 3.19+ do_execveat_common/__do_execve_file"
  echo "               faccessat -> '4.14 and older' SYSCALL_DEFINE3"
  echo "               reboot -> 3.18+ kernel/reboot.c"
  echo "  Android 15 does NOT need the sys_newfstat ret_hook (Android 16+ only)."
  echo
  local report="$OUT/hooks-preview.txt"
  mkdir -p "$OUT"
  {
    for spec in \
      "fs/exec.c:do_execveat_common" \
      "fs/exec.c:__do_execve_file" \
      "fs/open.c:SYSCALL_DEFINE3(faccessat" \
      "fs/stat.c:SYSCALL_DEFINE4(newfstatat" \
      "kernel/reboot.c:SYSCALL_DEFINE4(reboot"; do
      f="${KDIR}/${spec%%:*}"; pat="${spec#*:}"
      echo "===== ${spec%%:*}  /  $pat ====="
      if [ -f "$f" ]; then grep -n -A 22 -F "$pat" "$f" | head -30 || echo "(pattern not found)";
      else echo "(file missing)"; fi
      echo
    done
  } | tee "$report"
  echo "  Saved to $report"
  echo "  Insert the #ifdef CONFIG_KSU hook calls AFTER local variable declarations."
  echo "  Do not let this script guess: 4.4 is C89-style and inserting a statement"
  echo "  before declarations will fail to compile."
}

selfcheck() {
  log "Self-check"
  local ok=1
  [ -L "$KDIR/drivers/kernelsu" ] && echo "  OK  symlink drivers/kernelsu" || { echo "  MISSING symlink"; ok=0; }
  [ -f "$KDIR/drivers/kernelsu/Kconfig" ] && echo "  OK  drivers/kernelsu/Kconfig reachable" || { echo "  MISSING Kconfig"; ok=0; }
  grep -q 'CONFIG_KSU.*kernelsu/' "$KDIR/drivers/Makefile" && echo "  OK  drivers/Makefile" || { echo "  MISSING Makefile entry"; ok=0; }
  grep -q 'drivers/kernelsu/Kconfig' "$KDIR/drivers/Kconfig" && echo "  OK  drivers/Kconfig" || { echo "  MISSING Kconfig source"; ok=0; }
  grep -q '^CONFIG_KSU=y' "$KDIR/arch/arm64/configs/$DEFCONFIG" && echo "  OK  CONFIG_KSU=y" || { echo "  MISSING CONFIG_KSU"; ok=0; }
  grep -q '^CONFIG_KPROBES=y' "$KDIR/arch/arm64/configs/$DEFCONFIG" && echo "  OK  CONFIG_KPROBES=y" || { echo "  MISSING CONFIG_KPROBES"; ok=0; }

  # These headers do not exist in the pinned 4.4 tree. A live #include here
  # means apply_header_gates() did not run (or was reverted by a re-clone).
  # Check the EXACT file/header pair: kernel_includes.h also contains a
  # perfectly safe <linux/sched/signal.h> inside "#if >= 4.10", which 4.4
  # never expands. A file-wide grep would flag it and block a valid build.
  while read -r f hdr; do
    p="$KDIR/KernelSU/kernel/$f"
    [ -f "$p" ] || continue
    if grep -qE "^[[:space:]]*#include[[:space:]]*<${hdr}>" "$p"; then
      echo "  MISSING 4.4 header gate in $f ($hdr)"; ok=0
    fi
  done <<'GATES'
kernel_includes.h linux/static_call.h
infra/symbol_resolver.c linux/sched/signal.h
extension/kpm/compact.c linux/set_memory.h
extension/kpm/super_access.c linux/set_memory.h
GATES

  # If cpu_spoof.c still contains the 5.x vdso include, the 4.4 stub must be
  # there. Upstream removing that include on its own is fine (nothing to gate).
  p="$KDIR/KernelSU/kernel/extension/cpu_spoof.c"
  if [ -f "$p" ] && grep -q '<vdso/datapage.h>' "$p"; then
    grep -q 'dumpling-sukisu: 4.4 cpu_spoof stub' "$p" \
      || { echo "  MISSING 4.4 cpu_spoof stub"; ok=0; }
  fi

  # Run #7: these four gates are what make the KPM/SUSFS defconfig switches
  # real. Without them a re-clone silently restores the unbuildable code.
  while IFS='|' read -r f mark want; do
    p="$KDIR/KernelSU/kernel/$f"
    [ -f "$p" ] || continue
    got=$(grep -cF "$mark" "$p") || got=0
    if [ "$got" -lt "$want" ]; then
      echo "  MISSING 4.4 feature gate in $f (want $want markers, found $got)"
      ok=0
    fi
  done <<'FEATURES'
ksu_main.c|dumpling-sukisu: 4.4 KPM gate|1
extension/extension.c|dumpling-sukisu: 4.4 KPM gate|2
manager/pkg_observer.c|dumpling-sukisu: 4.4 SUSFS gate|2
kernel_compat.h|dumpling-sukisu: 4.4 kvcalloc shim|1
FEATURES

  if [ "$SUKISU_REF" = "builtin" ]; then
    # Check the exact injected marker in each expected file, not a file count:
    # a count of 3 could be satisfied by unrelated kernel code and let a
    # hook-less kernel through to a build that can never grant root.
    local missing=0
    for f in fs/exec.c fs/open.c fs/stat.c kernel/reboot.c; do
      grep -q 'dumpling-sukisu: manual hook' "$KDIR/$f" 2>/dev/null \
        || { echo "  MISSING manual hook in $f"; missing=1; }
    done
    if [ "$missing" -eq 0 ]; then
      echo "  OK  manual hooks present (4 sites)"
    else
      echo "  Run: ./build.sh hooks  to preview the real 4.4 hook sites."
      ok=0
    fi
  fi
  [ "$ok" -eq 1 ] || die "self-check failed; fix the lines above before building"
  echo "  All structural checks passed. Compile compatibility is still unverified on a real host."
}

compile_kernel() {
  log "Compiling 4.4.302 with $LLVM_TAG"
  export PATH="$WORK/android_prebuilts_build-tools-$PREBUILTS_HASH/path/linux-x86/:$PATH"
  export PATH="$WORK/android_prebuilts_build-tools-$PREBUILTS_HASH/linux-x86/bin/:$PATH"
  export PATH="$WORK/$LLVM_TAG/bin:$PATH"
  export PATH="$WORK/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9-$AARCH64_GCC_HASH/bin:$PATH"
  export PATH="$WORK/android_prebuilts_gcc_linux-x86_arm_arm-linux-androideabi-4.9-$ARM_GCC_HASH/bin:$PATH"

  cd "$KDIR"
  # The uname string lands in /proc/version, and DroidGuard (Play Integrity's
  # local evaluator) reads it against a blocklist of custom-kernel branding
  # ("Lineage" and variants hard-fail it; "sukisu" is the same class of
  # signal). A stock-looking banner costs nothing, so impersonate the
  # official LineageOS dumpling build: localversion "-perf+", builder
  # "root@7ce3fdbd9a43". Verified against the official boot.img on
  # 2026-11-10 (README 5.13).
  touch localversion
  printf -- '-perf+\n' > localversion
  export KBUILD_BUILD_USER=root
  export KBUILD_BUILD_HOST=7ce3fdbd9a43
  make -j"$(nproc --all)" O=out "$DEFCONFIG" ARCH=arm64 SUBARCH=arm64 LLVM=1
  make -j"$(nproc --all)" O=out \
    ARCH=arm64 SUBARCH=arm64 \
    CROSS_COMPILE=aarch64-linux-android- \
    CROSS_COMPILE_ARM32=arm-linux-androideabi- \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    LLVM=1
  [ -f "$KDIR/out/arch/arm64/boot/$KERNEL_IMAGE" ] || die "build finished without $KERNEL_IMAGE"
  echo "  built: $KDIR/out/arch/arm64/boot/$KERNEL_IMAGE"
}

pack_ak3() {
  log "Packing AnyKernel3 zip"
  local img="$KDIR/out/arch/arm64/boot/$KERNEL_IMAGE"
  [ -f "$img" ] || die "kernel image missing; run ./build.sh build first"
  [ -d "$AK3" ] || die "AnyKernel3 template missing; run ./build.sh prepare first"
  mkdir -p "$OUT"
  cp -f "$img" "$AK3/$KERNEL_IMAGE"
  cp -f "$ROOT/anykernel.sh" "$AK3/anykernel.sh"
  local name
  name="dumpling-$(ksu_product_tag)-${SUKISU_REF}-4.4.302-$(date +%Y%m%d-%H%M%S)"
  ( cd "$AK3" && zip -r9 -q "$OUT/$name.zip" . -x '.git*' 'README.md' '*placeholder' )
  echo "  output: $OUT/$name.zip"
  echo "  flash this zip in TWRP, then install the $(ksu_product_tag) Manager APK."
  echo "  rollback: restore your backed-up boot.img."
}

case "$STAGE" in
  prepare) download_all; integrate_sukisu; apply_compat_patches; gate_cpu_spoof; apply_header_gates; gate_optional_features; apply_manual_hooks; configure_defconfig; selfcheck ;;
  hooks)   [ -d "$KDIR" ] || die "run ./build.sh prepare first"; show_hooks ;;
  build)   [ -f "$KDIR/arch/arm64/configs/$DEFCONFIG" ] || die "run ./build.sh prepare first"; selfcheck; compile_kernel ;;
  pack)    pack_ak3 ;;
  all)     download_all; integrate_sukisu; apply_compat_patches; gate_cpu_spoof; apply_header_gates; gate_optional_features; apply_manual_hooks; configure_defconfig; selfcheck; compile_kernel; pack_ak3 ;;
  clean)   rm -rf "$WORK"; echo "removed $WORK" ;;
  *)       die "unknown stage '$STAGE' (use prepare|hooks|build|pack|all|clean)" ;;
esac
