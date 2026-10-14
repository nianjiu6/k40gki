import importlib.util
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "patch_resukisu_419.py"
SPEC = importlib.util.spec_from_file_location("patch_resukisu_419", MODULE_PATH)
PATCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PATCH)


class PatchReSukiSU419Tests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        original = PATCH.ROOT
        PATCH.ROOT = self.root
        self.addCleanup(setattr, PATCH, "ROOT", original)

    def put(self, name, contents):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
        return path

    def test_read_syscall_hook_passes_rc3_arguments(self):
        source = (MODULE_PATH.parents[1] / "fs/read_write.c").read_text(encoding="utf-8")
        self.assertRegex(
            source,
            r"extern int ksu_handle_sys_read\(unsigned int fd, char __user \*\*buf_ptr,\s*size_t \*count_ptr\);",
        )
        self.assertIn("ksu_handle_sys_read(fd, &buf, &count);", source)
        self.assertNotIn("ksu_handle_sys_read(fd);", source)

    def test_seccomp_patch_is_idempotent(self):
        path = self.put("policy/app_profile.c", "    put_seccomp_filter(current);\n    current->seccomp.filter = NULL;\n")
        PATCH.patch_disable_seccomp()
        patched = path.read_text(encoding="utf-8")
        self.assertNotIn("put_seccomp_filter(current);", patched)
        self.assertNotIn("current->seccomp.filter = NULL;", patched)
        PATCH.patch_disable_seccomp()
        self.assertEqual(path.read_text(encoding="utf-8"), patched)

    def test_unknown_seccomp_source_fails_without_partial_write(self):
        path = self.put("policy/app_profile.c", "    put_seccomp_filter(current);\n")
        original = path.read_bytes()
        with self.assertRaises(SystemExit):
            PATCH.patch_disable_seccomp()
        self.assertEqual(path.read_bytes(), original)

    def test_ioctl_patch_is_idempotent(self):
        path = self.put("supercall/supercall.c", "static long anon_ksu_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)\n{\n}\n")
        PATCH.patch_anon_ioctl_nocfi()
        patched = path.read_text(encoding="utf-8")
        self.assertIn("static noinline __nocfi long anon_ksu_ioctl", patched)
        PATCH.patch_anon_ioctl_nocfi()
        self.assertEqual(path.read_text(encoding="utf-8"), patched)

    def test_sucompat_guard_is_idempotent(self):
        path = self.put("feature/sucompat.c", "    old_cred = override_creds(ksu_cred);\n")
        PATCH.patch_sucompat_ksu_cred()
        patched = path.read_text(encoding="utf-8")
        self.assertIn("if (!ksu_cred)", patched)
        PATCH.patch_sucompat_ksu_cred()
        self.assertEqual(path.read_text(encoding="utf-8"), patched)


if __name__ == "__main__":
    unittest.main()
