import importlib.util
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "package_anykernel.py"
SPEC = importlib.util.spec_from_file_location("package_anykernel", MODULE_PATH)
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class PackageAnyKernelTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.workspace = root / "anykernel"
        self.output = root / "out"
        self.boot = self.output / "arch/arm64/boot"
        (self.boot / "dts/vendor/qcom").mkdir(parents=True)
        image = bytearray(64)
        image[56:60] = b"ARM\x64"
        (self.boot / "Image").write_bytes(image)
        for name, payload in (("b.dtb", b"B"), ("a.dtb", b"A")):
            (self.boot / "dts/vendor/qcom" / name).write_bytes(b"\xd0\x0d\xfe\xed" + payload)
        for required in ("tools/ak3-core.sh", "META-INF/com/google/android/update-binary"):
            path = self.workspace / required
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture", encoding="utf-8")

    def test_alioth_miui_preserves_dtbo_and_checks_device(self):
        (self.workspace / "dtbo.img").write_bytes(b"stale")
        (self.workspace / "kernels/miui").mkdir(parents=True)
        (self.workspace / "kernels/miui/dtbo.img").write_bytes(b"stale")
        PACKAGE.stage(self.workspace, self.output, "alioth", "miui")
        script = (self.workspace / "anykernel.sh").read_text(encoding="utf-8")
        self.assertIn("do.devicecheck=1", script)
        self.assertIn("device.name1=alioth", script)
        self.assertIn("supported.versions=13", script)
        self.assertNotIn("flash_generic", script)
        self.assertNotIn("userflavor", script)
        self.assertFalse((self.workspace / "dtbo.img").exists())
        self.assertFalse((self.workspace / "kernels").exists())
        self.assertEqual((self.workspace / "dtb").read_bytes(), b"\xd0\x0d\xfe\xedA\xd0\x0d\xfe\xedB")
        self.assertNotIn(b"\r\n", (self.workspace / "anykernel.sh").read_bytes())

    def test_other_variants_do_not_inherit_android13_restriction(self):
        PACKAGE.stage(self.workspace, self.output, "lmi", "aosp")
        script = (self.workspace / "anykernel.sh").read_text(encoding="utf-8")
        self.assertIn("device.name1=lmi", script)
        self.assertIn("supported.versions=\n", script)

    def test_invalid_device_is_rejected(self):
        with self.assertRaises(ValueError):
            PACKAGE.stage(self.workspace, self.output, "alioth;reboot", "miui")

    def test_non_arm64_image_is_rejected(self):
        (self.boot / "Image").write_bytes(bytes(64))
        with self.assertRaisesRegex(ValueError, "ARM64"):
            PACKAGE.stage(self.workspace, self.output, "alioth", "miui")

    def test_empty_dtb_set_is_rejected(self):
        for dtb in (self.boot / "dts").rglob("*.dtb"):
            dtb.unlink()
        with self.assertRaisesRegex(ValueError, "no compiled"):
            PACKAGE.stage(self.workspace, self.output, "alioth", "miui")

    def test_corrupt_dtb_is_rejected(self):
        (self.boot / "dts/vendor/qcom/a.dtb").write_bytes(b"bad")
        with self.assertRaisesRegex(ValueError, "invalid device tree"):
            PACKAGE.stage(self.workspace, self.output, "alioth", "miui")

    def test_missing_ak3_core_is_rejected(self):
        (self.workspace / "tools/ak3-core.sh").unlink()
        with self.assertRaisesRegex(ValueError, "missing AnyKernel3"):
            PACKAGE.stage(self.workspace, self.output, "alioth", "miui")


if __name__ == "__main__":
    unittest.main()
