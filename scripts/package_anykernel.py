#!/usr/bin/env python3
"""Stage one device/ROM variant without replacing the stock dtbo partition."""
from __future__ import annotations

import argparse
import re
import shutil
from pathlib import Path


def stage(workspace: Path, output: Path, device: str, target_os: str) -> None:
    if not re.fullmatch(r"[a-z0-9_]+", device) or target_os not in {"miui", "aosp"}:
        raise ValueError("invalid device or target OS")
    boot = output / "arch/arm64/boot"
    image = boot / "Image"
    dtbs = sorted((boot / "dts").rglob("*.dtb"))
    if not image.is_file() or image.stat().st_size < 64:
        raise ValueError(f"missing or truncated kernel Image: {image}")
    with image.open("rb") as stream:
        stream.seek(56)
        if stream.read(4) != b"ARM\x64":
            raise ValueError("Image does not have the ARM64 boot header magic")
    if not dtbs:
        raise ValueError("no compiled device trees found")
    for dtb in dtbs:
        with dtb.open("rb") as stream:
            if stream.read(4) != b"\xd0\x0d\xfe\xed":
                raise ValueError(f"invalid device tree: {dtb}")
    for required in ("tools/ak3-core.sh", "META-INF/com/google/android/update-binary"):
        if not (workspace / required).is_file():
            raise ValueError(f"missing AnyKernel3 component: {required}")

    shutil.rmtree(workspace / "kernels", ignore_errors=True)
    for stale in ("dtbo.img", "Image.gz", "Image.gz-dtb", "Image.lz4", "Image.lz4-dtb"):
        (workspace / stale).unlink(missing_ok=True)
    shutil.copyfile(image, workspace / "Image")
    with (workspace / "dtb").open("wb") as destination:
        for dtb in dtbs:
            with dtb.open("rb") as source:
                shutil.copyfileobj(source, destination)

    versions = "13" if device == "alioth" and target_os == "miui" else ""
    script = f'''### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

properties() {{ '
kernel.string=APTKernel {device} {target_os.upper()}
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1={device}
supported.versions={versions}
supported.patchlevels=
supported.vendorpatchlevels=
'; }}

BLOCK=boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;
NO_BLOCK_DISPLAY=1;

. tools/ak3-core.sh;

ui_print "Device: {device}; variant: {target_os.upper()}";
ui_print "Only boot is updated. Stock dtbo is preserved.";
[ -s "$AKHOME/Image" ] && [ -s "$AKHOME/dtb" ] || abort "Missing kernel payload";

split_boot;
flash_boot;
'''
    (workspace / "anykernel.sh").write_text(script, encoding="utf-8", newline="\n")
    print(f"Staged {device}/{target_os}: Image and {len(dtbs)} device trees; no dtbo")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workspace", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("device")
    parser.add_argument("target_os", choices=("miui", "aosp"))
    args = parser.parse_args()
    stage(args.workspace, args.output, args.device, args.target_os)


if __name__ == "__main__":
    main()
