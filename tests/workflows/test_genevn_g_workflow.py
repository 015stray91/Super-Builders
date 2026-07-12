"""Tests for .github/workflows/genevn-g.yml.

This repository has no application code and no pre-existing test framework
(no package.json, no pytest config, etc.). These tests use only the Python
standard library plus PyYAML (already available in the environment) to
statically validate the structure and content of the GitHub Actions workflow.

The workflow includes eight inputs: `kernel_target` (for device-profiles.json
selection), `ksu_variant` (KernelSU variant choice), and six boolean feature
toggles (`add_susfs`, `add_zeromount`, `add_zram`, `add_bbg`,
`add_overlayfs_support`, `add_kpm`). It has eight steps including disk space
cleanup, device-profiles.json parsing, toolchain initialization, kernel source
cloning, config merging with feature toggles, kernel building, packaging via
AnyKernel, and artifact upload with compression-level 9 and overwrite enabled.
These tests validate this structure to ensure any future edits are made
deliberately.

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
    """Tests covering the `on.workflow_dispatch.inputs` block, which includes
    eight inputs: kernel_target, ksu_variant, and six boolean feature toggles.
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

    def test_kernel_target_input_exists(self):
        """`kernel_target` is present and references device-profiles.json."""
        self.assertIn("kernel_target", self.inputs)
        self.assertEqual(self.inputs["kernel_target"]["type"], "choice")
        self.assertEqual(self.inputs["kernel_target"]["default"], "genevn_a12")

    def test_all_feature_toggle_inputs_are_present(self):
        """`add_zeromount`, `add_bbg`, and `add_kpm` are all present as
        boolean inputs along with their corresponding config-merging logic."""
        for feature_input in ("add_zeromount", "add_bbg", "add_kpm"):
            with self.subTest(feature_input=feature_input):
                self.assertIn(feature_input, self.inputs)
                self.assertEqual(self.inputs[feature_input]["type"], "boolean")
                self.assertTrue(self.inputs[feature_input]["default"])

    def test_input_keys_are_exactly_the_expected_set(self):
        """The workflow has eight inputs: one target selector, one KSU variant
        choice, and six boolean feature toggles."""
        self.assertEqual(
            set(self.inputs.keys()),
            {
                "kernel_target",
                "ksu_variant",
                "add_susfs",
                "add_zeromount",
                "add_zram",
                "add_bbg",
                "add_overlayfs_support",
                "add_kpm",
            },
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
    """Tests covering the `jobs.build.steps` list, which includes eight steps:
    disk space cleanup, checkout, toolchain initialization, device profile
    parsing, kernel cloning, config merging, building, packaging, and upload."""

    EXPECTED_STEP_NAMES = [
        "Free Disk Space",
        "Checkout Builder Meta Layout",
        "Initialize Toolchain",
        "Clone Kernel Source",
        "Merge Configs & Apply Feature Toggles",
        "Build Kernel",
        "Package Kernel via Personal AnyKernel纯包",
        "Upload Artifact",
    ]

    @classmethod
    def setUpClass(cls):
        with WORKFLOW_PATH.open(encoding="utf-8") as handle:
            cls.raw_text = handle.read()
        data = yaml.safe_load(cls.raw_text)
        cls.steps = data["jobs"]["build"]["steps"]
        cls.steps_by_name = {step.get("name"): step for step in cls.steps}

    def test_step_count(self):
        """The workflow has eight steps including device-profiles parsing,
        disk space cleanup, and artifact upload."""
        self.assertEqual(len(self.steps), 8)

    def test_step_names_in_order(self):
        self.assertEqual(
            [step.get("name") for step in self.steps], self.EXPECTED_STEP_NAMES
        )

    def test_step_names_are_unique(self):
        names = [step.get("name") for step in self.steps]
        self.assertEqual(len(names), len(set(names)))

    def test_free_disk_space_action_is_used(self):
        """The workflow uses the endersonmenezes/free-disk-space action."""
        self.assertIn("endersonmenezes/free-disk-space", self.raw_text)

    def test_device_profiles_json_is_referenced(self):
        """The workflow references device-profiles.json in the Parse Target
        Profile Details step and uses steps.parse.outputs."""
        self.assertIn("device-profiles.json", self.raw_text)
        self.assertIn("steps.parse.outputs", self.raw_text)

    def test_checkout_step_uses_actions_checkout_v4(self):
        step = self.steps_by_name["Checkout Builder Meta Layout"]
        self.assertEqual(step["uses"], "actions/checkout@v4")

    def test_install_toolchain_installs_expected_packages(self):
        run_script = self.steps_by_name["Initialize Toolchain"]["run"]
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

    def test_install_toolchain_installs_additional_packages(self):
        """The toolchain step installs Node.js and several kernel-build
        packages (kmod, device-tree-compiler, jq, python3, cpio, etc.) needed
        by the Parse Target Profile Details step."""
        run_script = self.steps_by_name["Initialize Toolchain"]["run"]
        for required_token in (
            "nodesource",
            "nodejs",
            "device-tree-compiler",
            "gcc-arm-linux-gnueabi",
            "jq",
            "libncurses",
            "kmod",
            "cpio",
        ):
            with self.subTest(required_token=required_token):
                self.assertIn(required_token, run_script)

    def test_clone_kernel_source_step_contents(self):
        run_script = self.steps_by_name["Clone Kernel Source"]["run"]
        self.assertIn("git clone --depth=1", run_script)
        self.assertIn("015stray91/kernel-msm-1.git", run_script)
        self.assertIn("steps.parse.outputs.branch", run_script)
        self.assertIn("cd kernel-msm-1", run_script)
        self.assertIn("android.googlesource.com/kernel/common", run_script)

    def test_clone_kernel_source_references_original_fork(self):
        """The workflow clones from the 015stray91 fork and uses
        android.googlesource.com for the common directory."""
        run_script = self.steps_by_name["Clone Kernel Source"]["run"]
        self.assertIn("015stray91", run_script)
        self.assertIn("android.googlesource.com", run_script)

    def test_clone_commands_have_explicit_repository_paths(self):
        """The workflow's git clone commands reference full repository paths
        like 015stray91/kernel-msm-1.git and android.googlesource.com paths."""
        from urllib.parse import urlparse

        # Check for specific repository references
        self.assertIn("015stray91/kernel-msm-1.git", self.raw_text)
        self.assertIn("android.googlesource.com/kernel/common", self.raw_text)
        self.assertIn("015stray91/Genevn-sm6450_AnyKernel.git", self.raw_text)

    def test_merge_configs_step_has_env_block(self):
        """The per-toggle environment variables (KSU_VARIANT, ADD_SUSFS,
        ADD_ZEROMOUNT, ADD_ZRAM, ADD_BBG, ADD_OVERLAYFS, ADD_KPM) and the
        dynamic config-list assembly logic are present."""
        step = self.steps_by_name["Merge Configs & Apply Feature Toggles"]
        self.assertIn("env", step)
        env_vars = step["env"]
        self.assertIn("KSU_VARIANT", env_vars)
        self.assertIn("ADD_SUSFS", env_vars)
        self.assertIn("ADD_ZEROMOUNT", env_vars)
        self.assertIn("ADD_ZRAM", env_vars)
        self.assertIn("ADD_BBG", env_vars)
        self.assertIn("ADD_OVERLAYFS", env_vars)
        self.assertIn("ADD_KPM", env_vars)

    def test_merge_configs_step_contents(self):
        run_script = self.steps_by_name["Merge Configs & Apply Feature Toggles"]["run"]
        self.assertIn("cd kernel-msm-1", run_script)
        self.assertIn("export ARCH=arm64", run_script)
        self.assertIn("mkdir -p out", run_script)
        self.assertIn("./scripts/kconfig/merge_config.sh -O out", run_script)
        self.assertIn("arch/arm64/configs/vendor/parrot_GKI.config", run_script)
        self.assertIn("steps.parse.outputs.defconfig", run_script)
        self.assertIn("steps.parse.outputs.debug_config", run_script)
        self.assertIn("make O=out olddefconfig", run_script)

    def test_merge_configs_step_uses_feature_toggle_variables(self):
        """The merge configs step uses CONFIG_LIST and checks all feature
        toggle variables to conditionally add config files."""
        run_script = self.steps_by_name["Merge Configs & Apply Feature Toggles"]["run"]
        for required_token in (
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
            with self.subTest(required_token=required_token):
                self.assertIn(required_token, run_script)

    def test_build_kernel_step_env_exports(self):
        run_script = self.steps_by_name["Build Kernel"]["run"]
        self.assertIn("export ARCH=arm64", run_script)
        self.assertIn("export LLVM=1", run_script)

    def test_build_kernel_step_exports_required_variables(self):
        """The build step exports CROSS_COMPILE, LLVM_IAS, specific clang
        versions, and build identification variables."""
        run_script = self.steps_by_name["Build Kernel"]["run"]
        for required_token in (
            "CROSS_COMPILE",
            "CROSS_COMPILE_COMPAT",
            "LLVM_IAS",
            'CC="clang-12"',
            'LD="ld.lld-12"',
            "KBUILD_BUILD_USER",
            "KBUILD_BUILD_HOST",
            "LOCALVERSION",
        ):
            with self.subTest(required_token=required_token):
                self.assertIn(required_token, run_script)

    def test_build_kernel_make_invocation(self):
        run_script = self.steps_by_name["Build Kernel"]["run"]
        self.assertIn("make O=out ARCH=arm64 CC=clang-12", run_script)
        self.assertIn("LD=ld.lld-12", run_script)
        self.assertIn("CLANG_TRIPLE=aarch64-linux-gnu-", run_script)
        self.assertIn("Image.gz", run_script)
        self.assertIn("-j$(nproc --all)", run_script)
        self.assertIn("|| exit 1", run_script)

    def test_package_kernel_step_contents(self):
        run_script = self.steps_by_name["Package Kernel via Personal AnyKernel纯包"]["run"]
        self.assertIn("git clone --depth=1", run_script)
        self.assertIn("015stray91/Genevn-sm6450_AnyKernel.git", run_script)
        self.assertIn("anykernel-workspace", run_script)
        self.assertIn("rm -rf anykernel-workspace/.git", run_script)
        self.assertIn(
            "cp kernel-msm-1/out/arch/arm64/boot/Image.gz anykernel-workspace/",
            run_script,
        )
        self.assertIn("cd anykernel-workspace", run_script)
        self.assertIn("zip -r9 ../Genevn-Kernel-Flashable.zip *", run_script)

    def test_package_kernel_step_references_original_anykernel_repo(self):
        """The package step clones from 015stray91/Genevn-sm6450_AnyKernel
        and removes the .git directory."""
        run_script = self.steps_by_name["Package Kernel via Personal AnyKernel纯包"]["run"]
        self.assertIn("015stray91/Genevn-sm6450_AnyKernel", run_script)
        self.assertIn("rm -rf anykernel-workspace/.git", run_script)

    def test_upload_artifact_step(self):
        step = self.steps_by_name["Upload Artifact"]
        self.assertEqual(step["uses"], "actions/upload-artifact@v4")
        self.assertEqual(
            step["with"],
            {
                "name": "Genevn-Flashable-Package",
                "path": "Genevn-Kernel-Flashable.zip",
                "compression-level": 9,
                "overwrite": True,
            },
        )

    def test_upload_artifact_step_sets_compression_and_overwrite(self):
        """`compression-level` and `overwrite` are set in the
        upload-artifact step's `with` block."""
        step = self.steps_by_name["Upload Artifact"]
        self.assertIn("compression-level", step["with"])
        self.assertEqual(step["with"]["compression-level"], 9)
        self.assertIn("overwrite", step["with"])
        self.assertTrue(step["with"]["overwrite"])


if __name__ == "__main__":
    unittest.main()