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
# Override the SukiSU branch (the workflow picks the default, not this script):
#   SUKISU_REF=builtin ./build.sh all     full 4.4 compat layer; hooks inserted below
#   SUKISU_REF=old     ./build.sh all     kprobes + generated 4.4 compat shims
#   SUKISU_REF=main    ./build.sh all     proven broken on 4.4 (Run #1)
#
# IMPORTANT / honest scope:
#   Every URL, hash, defconfig name, build command and AK3 property in this
#   script was read from upstream source files on 2026-11-08 (see toolchain.conf).
#   The script itself was NOT compiled end-to-end: it was authored on a Windows
#   host with no Linux kernel toolchain. `prepare` performs a real self-check;
#   `build` is where 4.4-vs-modern-SukiSU compatibility is actually proven.
#   The generated C shims and injected hook calls have never been compiled on a
#   real 4.4 tree. A compile failure is NOT automatically a script bug: 4.4 is
#   a legacy target and modern SukiSU may need backports we have not found yet.
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
  log "Integrating SukiSU-Ultra ($SUKISU_REF) into the kernel tree"
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
  touch localversion
  printf -- '-sukisu-dumpling\n' > localversion
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
  name="dumpling-SukiSU-${SUKISU_REF}-4.4.302-$(date +%Y%m%d-%H%M%S)"
  ( cd "$AK3" && zip -r9 -q "$OUT/$name.zip" . -x '.git*' 'README.md' '*placeholder' )
  echo "  output: $OUT/$name.zip"
  echo "  flash this zip in TWRP, then install the SukiSU Manager APK."
  echo "  rollback: restore your backed-up boot.img."
}

case "$STAGE" in
  prepare) download_all; integrate_sukisu; apply_compat_patches; apply_manual_hooks; configure_defconfig; selfcheck ;;
  hooks)   [ -d "$KDIR" ] || die "run ./build.sh prepare first"; show_hooks ;;
  build)   [ -f "$KDIR/arch/arm64/configs/$DEFCONFIG" ] || die "run ./build.sh prepare first"; selfcheck; compile_kernel ;;
  pack)    pack_ak3 ;;
  all)     download_all; integrate_sukisu; apply_compat_patches; apply_manual_hooks; configure_defconfig; selfcheck; compile_kernel; pack_ak3 ;;
  clean)   rm -rf "$WORK"; echo "removed $WORK" ;;
  *)       die "unknown stage '$STAGE' (use prepare|hooks|build|pack|all|clean)" ;;
esac
