"""Tests for .github/workflows/genevn-g.yml.

This repository has no application code and no pre-existing test framework
(no package.json, no pytest config, etc.). These tests use only the Python
standard library plus PyYAML (already available in the environment) to
statically validate the structure and content of the GitHub Actions workflow
that was changed in this PR.

The PR gutted `genevn-g.yml`: it removed the `kernel_target` input and the
`device-profiles.json`-driven config parsing/merging logic, removed several
feature-toggle inputs (`add_zeromount`, `add_bbg`, `add_kpm`), removed the
disk-space cleanup step, and replaced several `git clone` invocations with
plain hostnames. These tests pin down the resulting (changed) structure so
that any further edits to the workflow are made deliberately.

Note: PyYAML resolves the unquoted YAML 1.1 boolean-like scalar key `on:` to
the Python boolean `True` rather than the string `"on"`. `ON_KEY` below
captures that quirk so the tests read clearly.
"""

import re
import unittest
from pathlib import Path

import yaml

WORKFLOW_PATH = (
    Path(__file__).resolve().parents[2] / ".github" / "workflows" / "genevn-g.yml"
)

# PyYAML's SafeLoader resolves the bare `on:` mapping key to the boolean
# `True` (YAML 1.1 boolean scalar resolution), not the string "on".
ON_KEY = True


class WorkflowLoadingTests(unittest.TestCase):
    """Basic sanity checks that the workflow file exists and parses."""

    def test_workflow_file_exists(self):
        self.assertTrue(
            WORKFLOW_PATH.is_file(), f"Expected workflow file at {WORKFLOW_PATH}"
        )

    def test_workflow_loads_as_valid_yaml(self):
        with WORKFLOW_PATH.open(encoding="utf-8") as handle:
            data = yaml.safe_load(handle)
        self.assertIsInstance(data, dict)
        self.assertIn("name", data)
        self.assertIn("jobs", data)
        self.assertIn(ON_KEY, data)

    def test_workflow_name(self):
        with WORKFLOW_PATH.open(encoding="utf-8") as handle:
            data = yaml.safe_load(handle)
        self.assertEqual(data["name"], "Genevn Custom Toolchain Build")


class WorkflowDispatchInputsTests(unittest.TestCase):
    """Tests covering the `on.workflow_dispatch.inputs` block, which was
    heavily modified by this PR (kernel_target and several booleans removed).
    """

    @classmethod
    def setUpClass(cls):
        with WORKFLOW_PATH.open(encoding="utf-8") as handle:
            data = yaml.safe_load(handle)
        cls.inputs = data[ON_KEY]["workflow_dispatch"]["inputs"]

    def test_trigger_is_workflow_dispatch_only(self):
        with WORKFLOW_PATH.open(encoding="utf-8") as handle:
            data = yaml.safe_load(handle)
        self.assertEqual(list(data[ON_KEY].keys()), ["workflow_dispatch"])

    def test_kernel_target_input_was_removed(self):
        """`kernel_target` (and its device-profiles.json selection) was
        removed entirely by this PR."""
        self.assertNotIn("kernel_target", self.inputs)

    def test_removed_feature_toggle_inputs_are_absent(self):
        """`add_zeromount`, `add_bbg`, and `add_kpm` were removed by this
        PR along with their corresponding config-merging logic."""
        for removed_input in ("add_zeromount", "add_bbg", "add_kpm"):
            self.assertNotIn(removed_input, self.inputs)

    def test_input_keys_are_exactly_the_expected_set(self):
        self.assertEqual(
            set(self.inputs.keys()),
            {"ksu_variant", "add_susfs", "add_zram", "add_overlayfs_support"},
        )

    def test_ksu_variant_input_definition(self):
        ksu_variant = self.inputs["ksu_variant"]
        self.assertEqual(ksu_variant["type"], "choice")
        self.assertEqual(
            ksu_variant["options"],
            ["KernelSU-Next", "SukiSU", "ReSukiSU", "WKSU"],
        )
        self.assertEqual(ksu_variant["default"], "KernelSU-Next")

    def test_remaining_boolean_inputs_default_to_true(self):
        for boolean_input in ("add_susfs", "add_zram", "add_overlayfs_support"):
            with self.subTest(boolean_input=boolean_input):
                definition = self.inputs[boolean_input]
                self.assertEqual(definition["type"], "boolean")
                self.assertTrue(definition["default"])


class WorkflowJobTests(unittest.TestCase):
    """Tests covering top level `jobs.build` metadata."""

    @classmethod
    def setUpClass(cls):
        with WORKFLOW_PATH.open(encoding="utf-8") as handle:
            data = yaml.safe_load(handle)
        cls.jobs = data["jobs"]
        cls.build_job = cls.jobs["build"]

    def test_only_one_job_is_defined(self):
        self.assertEqual(list(self.jobs.keys()), ["build"])

    def test_build_job_metadata(self):
        self.assertEqual(self.build_job["name"], "Build Custom Kernel - Genevn")
        self.assertEqual(self.build_job["runs-on"], "ubuntu-22.04")


class WorkflowStepsTests(unittest.TestCase):
    """Tests covering the `jobs.build.steps` list, which this PR rewrote
    almost entirely (removed the disk-space-cleanup step, the parse-profile
    step, and simplified/renamed several remaining steps)."""

    EXPECTED_STEP_NAMES = [
        "Checkout Code",
        "Install Toolchain",
        "Clone Kernel Source",
        "Merge Configs & Apply Features",
        "Build Kernel",
        "Package Kernel",
        "Upload Artifact",
    ]

    REMOVED_STEP_NAMES = [
        "Free Disk Space",
        "Checkout Builder Meta Layout",
        "Initialize Toolchain",
        "Parse Target Profile Details",
        "Merge Configs & Apply Feature Toggles",
        "Package Kernel via Personal AnyKernel纯包",
    ]

    @classmethod
    def setUpClass(cls):
        with WORKFLOW_PATH.open(encoding="utf-8") as handle:
            cls.raw_text = handle.read()
        data = yaml.safe_load(cls.raw_text)
        cls.steps = data["jobs"]["build"]["steps"]
        cls.steps_by_name = {step.get("name"): step for step in cls.steps}

    def test_step_count(self):
        self.assertEqual(len(self.steps), 7)

    def test_step_names_in_order(self):
        self.assertEqual(
            [step.get("name") for step in self.steps], self.EXPECTED_STEP_NAMES
        )

    def test_step_names_are_unique(self):
        names = [step.get("name") for step in self.steps]
        self.assertEqual(len(names), len(set(names)))

    def test_removed_step_names_are_absent(self):
        current_names = {step.get("name") for step in self.steps}
        for removed_name in self.REMOVED_STEP_NAMES:
            self.assertNotIn(removed_name, current_names)

    def test_free_disk_space_action_no_longer_used(self):
        self.assertNotIn("endersonmenezes/free-disk-space", self.raw_text)

    def test_device_profiles_json_no_longer_referenced(self):
        self.assertNotIn("device-profiles.json", self.raw_text)
        self.assertNotIn("steps.parse.outputs", self.raw_text)

    def test_checkout_step_uses_actions_checkout_v4(self):
        step = self.steps_by_name["Checkout Code"]
        self.assertEqual(step["uses"], "actions/checkout@v4")

    def test_install_toolchain_installs_expected_packages(self):
        run_script = self.steps_by_name["Install Toolchain"]["run"]
        for package in (
            "clang-12",
            "lld-12",
            "llvm-12",
            "gcc-aarch64-linux-gnu",
            "bc",
            "bison",
            "flex",
            "libssl-dev",
            "libelf-dev",
            "make",
        ):
            with self.subTest(package=package):
                self.assertIn(package, run_script)

    def test_install_toolchain_does_not_install_removed_packages(self):
        """Node.js setup and several kernel-build-only packages (kmod,
        device-tree-compiler, jq, python3, cpio, etc.) were removed by this
        PR, along with the whole `Parse Target Profile Details` step that
        depended on `jq`."""
        run_script = self.steps_by_name["Install Toolchain"]["run"]
        for removed_token in (
            "nodesource",
            "nodejs",
            "device-tree-compiler",
            "gcc-arm-linux-gnueabi",
            "jq",
            "libncurses",
            "kmod",
            "cpio",
            "python3",
        ):
            with self.subTest(removed_token=removed_token):
                self.assertNotIn(removed_token, run_script)

    def test_clone_kernel_source_step_contents(self):
        run_script = self.steps_by_name["Clone Kernel Source"]["run"]
        self.assertIn(
            "git clone --depth=1 -b android-14-release https://github.com kernel-msm-1",
            run_script,
        )
        self.assertIn("cd kernel-msm-1", run_script)
        self.assertIn(
            "git clone --depth=1 https://googlesource.com common", run_script
        )

    def test_clone_kernel_source_no_longer_references_original_fork(self):
        run_script = self.steps_by_name["Clone Kernel Source"]["run"]
        self.assertNotIn("015stray91", run_script)
        self.assertNotIn("android.googlesource.com", run_script)

    def test_clone_commands_lack_an_explicit_repository_path(self):
        """Regression/negative check pinning a defect introduced by this PR:
        every `git clone` URL in the workflow now points at a bare hostname
        (e.g. `https://github.com`) instead of a full `owner/repo` path, so
        none of these clones can succeed as written. If this workflow is
        ever fixed to clone real repositories, this test should be updated
        to assert the corrected, non-empty repository paths.
        """
        from urllib.parse import urlparse

        urls = re.findall(r"https?://\S+", self.raw_text)
        self.assertTrue(urls, "Expected at least one clone URL in the workflow")
        for url in urls:
            with self.subTest(url=url):
                path = urlparse(url).path
                self.assertIn(path, ("", "/"))

    def test_merge_configs_step_has_no_env_block(self):
        """The per-toggle environment variables (KSU_VARIANT, ADD_SUSFS,
        ADD_ZEROMOUNT, ADD_ZRAM, ADD_BBG, ADD_OVERLAYFS, ADD_KPM) and the
        dynamic config-list assembly logic were removed by this PR."""
        step = self.steps_by_name["Merge Configs & Apply Features"]
        self.assertNotIn("env", step)

    def test_merge_configs_step_contents(self):
        run_script = self.steps_by_name["Merge Configs & Apply Features"]["run"]
        self.assertIn("cd kernel-msm-1", run_script)
        self.assertIn("export ARCH=arm64", run_script)
        self.assertIn("mkdir -p out", run_script)
        self.assertIn("./scripts/kconfig/merge_config.sh -O out", run_script)
        self.assertIn("arch/arm64/configs/vendor/parrot_GKI.config", run_script)
        self.assertIn("arch/arm64/configs/ksu-nh.defconfig", run_script)
        self.assertIn("make O=out olddefconfig", run_script)

    def test_merge_configs_step_no_longer_uses_feature_toggle_variables(self):
        run_script = self.steps_by_name["Merge Configs & Apply Features"]["run"]
        for removed_token in (
            "CONFIG_LIST",
            "ADD_SUSFS",
            "ADD_ZEROMOUNT",
            "ADD_BBG",
            "ADD_KPM",
            "susfs.config",
            "zeromount.config",
            "bbg.config",
            "kpm.config",
            "ksu-next.config",
            "sukisu.config",
        ):
            with self.subTest(removed_token=removed_token):
                self.assertNotIn(removed_token, run_script)

    def test_build_kernel_step_env_exports(self):
        run_script = self.steps_by_name["Build Kernel"]["run"]
        self.assertIn("export ARCH=arm64", run_script)
        self.assertIn("export LLVM=1", run_script)

    def test_build_kernel_step_no_longer_exports_removed_variables(self):
        run_script = self.steps_by_name["Build Kernel"]["run"]
        for removed_token in (
            "CROSS_COMPILE",
            "CROSS_COMPILE_COMPAT",
            "LLVM_IAS",
            'CC="clang-12"',
            'LD="ld.lld-12"',
            "KBUILD_BUILD_USER",
            "KBUILD_BUILD_HOST",
            "LOCALVERSION",
        ):
            with self.subTest(removed_token=removed_token):
                self.assertNotIn(removed_token, run_script)

    def test_build_kernel_make_invocation(self):
        run_script = self.steps_by_name["Build Kernel"]["run"]
        self.assertIn(
            "make O=out ARCH=arm64 CC=clang-12 Image.gz -j$(nproc --all)",
            run_script,
        )
        self.assertNotIn("|| exit 1", run_script)

    def test_package_kernel_step_contents(self):
        run_script = self.steps_by_name["Package Kernel"]["run"]
        self.assertIn("git clone --depth=1 https://github.com anykernel-workspace", run_script)
        self.assertIn(
            "cp kernel-msm-1/out/arch/arm64/boot/Image.gz anykernel-workspace/",
            run_script,
        )
        self.assertIn("cd anykernel-workspace", run_script)
        self.assertIn("zip -r9 ../Genevn-Kernel-Flashable.zip *", run_script)

    def test_package_kernel_step_no_longer_references_original_anykernel_repo(self):
        run_script = self.steps_by_name["Package Kernel"]["run"]
        self.assertNotIn("015stray91/Genevn-sm6450_AnyKernel", run_script)
        self.assertNotIn("rm -rf anykernel-workspace/.git", run_script)

    def test_upload_artifact_step(self):
        step = self.steps_by_name["Upload Artifact"]
        self.assertEqual(step["uses"], "actions/upload-artifact@v4")
        self.assertEqual(
            step["with"],
            {
                "name": "Genevn-Flashable-Package",
                "path": "Genevn-Kernel-Flashable.zip",
            },
        )

    def test_upload_artifact_step_no_longer_sets_removed_options(self):
        """`compression-level` and `overwrite` were removed from the
        upload-artifact step's `with` block by this PR."""
        step = self.steps_by_name["Upload Artifact"]
        self.assertNotIn("compression-level", step["with"])
        self.assertNotIn("overwrite", step["with"])


if __name__ == "__main__":
    unittest.main()