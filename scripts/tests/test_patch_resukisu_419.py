import importlib.util
import os
import re
import shutil
import subprocess
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


class Uapi5ServicesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(os.environ.get("KSU_SOURCE_DIR", "KernelSU"))
        if not cls.source.is_dir():
            raise unittest.SkipTest("KernelSU source is not present yet")
        cls.header = (cls.source / "uapi/supercall.h").read_text(encoding="utf-8")
        cls.dispatch = (cls.source / "kernel/supercall/dispatch.c").read_text(encoding="utf-8")

    def test_uapi5_has_services_event(self):
        self.assertIn("KERNEL_SU_UAPI_VERSION = 5;", self.header)
        self.assertIn("DEFINE_KSU_UAPI_CONST(__u32, EVENT_SERVICES, 4)", self.header)
        self.assertIn("case EVENT_SERVICES:", self.dispatch)

    def test_actual_services_handler_start_skip_reset(self):
        compiler = shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
        self.assertIsNotNone(compiler, "a host C compiler is required")
        start = self.dispatch.index("static int do_report_event(void __user *arg)")
        end = self.dispatch.index("static int do_set_sepolicy", start)
        handler = self.dispatch[start:end]
        events = dict(re.findall(
            r"DEFINE_KSU_UAPI_CONST\(__u32, (EVENT_\w+), (\d+)\)", self.header
        ))
        declarations = "\n".join(f"#define {name} {value}" for name, value in events.items())
        source = r'''
#include <assert.h>
#include <stdbool.h>
#include <string.h>
#include <errno.h>
#define __user
#define CONFIG_KSU_SUSFS 1
#define pr_info(...) ((void)0)
struct ksu_report_event_cmd { unsigned int event; };
static bool ksu_late_loaded;
static int post_count, boot_count, mount_count, sdcard_count;
static int copy_from_user(void *dst, const void *src, unsigned long size) {
    if (!src) return 1;
    memcpy(dst, src, size);
    return 0;
}
static void on_post_fs_data(void) { post_count++; }
static void on_boot_completed(void) { boot_count++; }
static void on_module_mounted(void) { mount_count++; }
static void susfs_start_sdcard_monitor_fn(void) { sdcard_count++; }
'''
        source += declarations + "\n" + handler + r'''
static int report(unsigned int event) {
    struct ksu_report_event_cmd cmd = {event};
    return do_report_event(&cmd);
}
int main(void) {
    assert(do_report_event(0) == -EFAULT);
    assert(report(EVENT_POST_FS_DATA) == 0);
    assert(report(EVENT_SERVICES) == 1);
    assert(report(EVENT_SERVICES) == 0);
    assert(do_report_event(0) == -EFAULT);
    assert(report(EVENT_SERVICES) == 0);
    assert(report(999) == 0);
    assert(report(EVENT_SERVICES) == 0);
    assert(report(EVENT_POST_FS_DATA) == 0);
    assert(post_count == 1);
    assert(report(EVENT_SERVICES) == 1);
    assert(report(EVENT_SERVICES) == 0);
    assert(report(EVENT_BOOT_COMPLETED) == 0);
    assert(report(EVENT_BOOT_COMPLETED) == 0);
    assert(boot_count == 1 && sdcard_count == 1);
    assert(report(EVENT_MODULE_MOUNTED) == 0);
    assert(mount_count == 1);
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / ("services.exe" if os.name == "nt" else "services")
            subprocess.run(
                [compiler, "-x", "c", "-", "-o", str(executable)],
                input=source, text=True, check=True, capture_output=True,
            )
            subprocess.run([str(executable)], check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
