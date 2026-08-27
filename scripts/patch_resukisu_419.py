#!/usr/bin/env python3
"""Patch cloned ReSukiSU so the manager can start on Linux 4.19 / QCOM.

Opening the manager is the only userspace path that:
  1. is auto-allowlisted
  2. still has zygote seccomp attached
  3. therefore always calls disable_seccomp() on kernels < 5.10

put_seccomp_filter() plus CONFIG_PANIC_ON_REFCOUNT_ERROR=y turns that into an
immediate watchdog reboot (CONFIG_QCOM_FORCE_WDOG_BITE_ON_PANIC).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path("KernelSU/kernel")


def die(msg: str) -> None:
    print(f"[!] {msg}")
    sys.exit(1)


def read(path: Path) -> str:
    if not path.exists():
        die(f"missing {path}")
    return path.read_text(encoding="utf-8", errors="replace")


def write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def patch_disable_seccomp() -> None:
    path = ROOT / "policy" / "app_profile.c"
    text = read(path)

    if "4.19/QCOM: skip put_seccomp_filter" in text:
        print("[-] disable_seccomp: already patched")
        return

    text2, n = re.subn(
        r"[ \t]*put_seccomp_filter\(current\);",
        "    /* 4.19/QCOM: skip put_seccomp_filter, see below */",
        text,
        count=1,
    )
    if n != 1:
        die("disable_seccomp: put_seccomp_filter(current) not found")

    text3, n = re.subn(
        r"[ \t]*current->seccomp\.filter = NULL;",
        "    /* Keep filter pointer. TIF_SECCOMP is already cleared so it will not run.\n"
        "     * Putting the zygote-shared filter races CONFIG_PANIC_ON_REFCOUNT_ERROR\n"
        "     * and reboots K40 when the manager is launched. */",
        text2,
        count=1,
    )
    if n != 1:
        die("disable_seccomp: current->seccomp.filter = NULL not found")

    write(path, text3)
    print("[+] disable_seccomp: 4.19-safe (no put, no NULL)")


def patch_sucompat_ksu_cred() -> None:
    path = ROOT / "feature" / "sucompat.c"
    text = read(path)

    needle = "    old_cred = override_creds(ksu_cred);"
    repl = (
        "    if (!ksu_cred)\n"
        "        return 0;\n"
        "    old_cred = override_creds(ksu_cred);"
    )
    if "if (!ksu_cred)" in text and "override_creds(ksu_cred)" in text:
        print("[-] sucompat: ksu_cred guard already present")
        return
    if needle not in text:
        print("[-] sucompat: override_creds(ksu_cred) not found, skip")
        return
    write(path, text.replace(needle, repl))
    print("[+] sucompat: ksu_cred NULL guard")


def patch_anon_ioctl_nocfi() -> None:
    path = ROOT / "supercall" / "supercall.c"
    text = read(path)

    old = "static long anon_ksu_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)"
    new = "static noinline __nocfi long anon_ksu_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)"
    if new in text:
        print("[-] supercall: anon_ksu_ioctl already nocfi")
        return
    if old not in text:
        die("supercall: anon_ksu_ioctl not found")
    write(path, text.replace(old, new, 1))
    print("[+] supercall: anon_ksu_ioctl marked __nocfi")


def main() -> None:
    if not ROOT.exists():
        die(f"{ROOT} not found (ReSukiSU setup did not run)")
    patch_disable_seccomp()
    patch_sucompat_ksu_cred()
    patch_anon_ioctl_nocfi()
    print("[+] ReSukiSU 4.19 runtime patches applied")


if __name__ == "__main__":
    main()
