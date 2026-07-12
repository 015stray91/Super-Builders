"""Unit tests for .github/workflows/genevn-g.yml.

These tests validate the structure and content of the "Genevn Custom
Toolchain Build" GitHub Actions workflow. They are plain-YAML/structural
tests (no GitHub Actions runner is invoked) and only rely on Python's
standard library plus PyYAML, which is already available in this
environment.

Notably, the previous revision of this workflow had a "Parse Target
Profile Details" step whose `id:`/`run:` keys were mis-indented so that it
was nested *inside* the `run:` block scalar of the preceding "Initialize
Toolchain" step, rather than being its own step. That made the file
"parse" as valid YAML but produced a step list that did not match the
authors' intent, and any `${{ steps.parse.outputs.* }}` expression would
have resolved to an empty string at runtime. The current revision removes
that entire code path (and the `kernel_target` input / device-profiles.json
lookup that fed it) in favor of hard-coded config paths. These tests lock
in that fix and the resulting structure so regressions are caught early.
"""

import os
import unittest

import yaml

WORKFLOW_PATH = os.path.normpath(
    os.path.join(
        os.path.dirname(__file__),
        "..",
        "..",
        ".github",
        "workflows",
        "genevn-g.yml",
    )
)


def _load_workflow(path):
    with open(path, "r", encoding="utf-8") as handle:
        raw = handle.read()
    # PyYAML's default (YAML 1.1) resolver treats the bare scalar key
    # "on" as the boolean `True`, which is a well known gotcha when
    # parsing GitHub Actions workflow files. Both the un-parsed text and
    # the parsed document are returned so tests can pick whichever is
    # more convenient.
    parsed = yaml.safe_load(raw)
    return raw, parsed


def _get_on_section(workflow):
    """Return the workflow's `on:` mapping, accounting for the YAML 1.1
    boolean-key gotcha described above."""
    if "on" in workflow:
        return workflow["on"]
    return workflow[True]


class GenevnGWorkflowStructureTest(unittest.TestCase):
    """Top-level document structure tests."""

    @classmethod
    def setUpClass(cls):
        cls.raw, cls.workflow = _load_workflow(WORKFLOW_PATH)

    def test_workflow_file_exists(self):
        self.assertTrue(
            os.path.isfile(WORKFLOW_PATH), f"Missing workflow file at {WORKFLOW_PATH}"
        )

    def test_workflow_is_valid_single_document_yaml(self):
        # Regression test: an earlier revision of this file had a step
        # whose keys were mis-indented into the previous step's `run:`
        # block. That version still "parsed" (because everything was
        # swallowed into a single scalar string) but yaml.safe_load_all
        # would only ever yield one malformed document. Asserting we get
        # exactly one well-formed mapping guards against that class of bug.
        with open(WORKFLOW_PATH, "r", encoding="utf-8") as handle:
            documents = list(yaml.safe_load_all(handle))
        self.assertEqual(len(documents), 1)
        self.assertIsInstance(documents[0], dict)

    def test_top_level_keys(self):
        self.assertEqual(
            set(self.workflow.keys()), {"name", "permissions", True, "jobs"}
        )

    def test_workflow_name(self):
        self.assertEqual(self.workflow["name"], "Genevn Custom Toolchain Build")

    def test_permissions_block(self):
        self.assertEqual(
            self.workflow["permissions"], {"contents": "write", "actions": "write"}
        )


class GenevnGWorkflowTriggerTest(unittest.TestCase):
    """Tests for the `on.workflow_dispatch` trigger and its inputs."""

    @classmethod
    def setUpClass(cls):
        cls.raw, cls.workflow = _load_workflow(WORKFLOW_PATH)
        cls.on_section = _get_on_section(cls.workflow)

    def test_only_trigger_is_workflow_dispatch(self):
        self.assertEqual(list(self.on_section.keys()), ["workflow_dispatch"])

    def test_inputs_only_contain_expected_keys(self):
        inputs = self.on_section["workflow_dispatch"]["inputs"]
        self.assertEqual(
            set(inputs.keys()),
            {"ksu_variant", "add_susfs", "add_zram", "add_overlayfs_support"},
        )

    def test_kernel_target_input_removed(self):
        inputs = self.on_section["workflow_dispatch"]["inputs"]
        self.assertNotIn("kernel_target", inputs)

    def test_removed_feature_toggle_inputs_are_absent(self):
        # add_zeromount, add_bbg and add_kpm were removed from the input
        # list; their corresponding config files must no longer be
        # toggle-able from workflow_dispatch.
        inputs = self.on_section["workflow_dispatch"]["inputs"]
        for removed_input in ("add_zeromount", "add_bbg", "add_kpm"):
            self.assertNotIn(removed_input, inputs)

    def test_ksu_variant_input_definition(self):
        ksu_variant = self.on_section["workflow_dispatch"]["inputs"]["ksu_variant"]
        self.assertEqual(ksu_variant["type"], "choice")
        self.assertEqual(ksu_variant["description"], "KernelSU variant")
        self.assertEqual(
            ksu_variant["options"],
            ["KernelSU-Next", "SukiSU", "ReSukiSU", "WKSU"],
        )
        self.assertEqual(ksu_variant["default"], "KernelSU-Next")
        # The default must always be one of the declared options.
        self.assertIn(ksu_variant["default"], ksu_variant["options"])

    def test_boolean_feature_inputs(self):
        inputs = self.on_section["workflow_dispatch"]["inputs"]
        for boolean_input in ("add_susfs", "add_zram", "add_overlayfs_support"):
            with self.subTest(input_name=boolean_input):
                self.assertEqual(inputs[boolean_input]["type"], "boolean")
                self.assertIs(inputs[boolean_input]["default"], True)


class GenevnGWorkflowJobTest(unittest.TestCase):
    """Tests for the `jobs.build` job shape."""

    @classmethod
    def setUpClass(cls):
        cls.raw, cls.workflow = _load_workflow(WORKFLOW_PATH)
        cls.jobs = cls.workflow["jobs"]

    def test_only_job_is_build(self):
        self.assertEqual(list(self.jobs.keys()), ["build"])

    def test_build_job_metadata(self):
        build_job = self.jobs["build"]
        self.assertEqual(build_job["name"], "Build Custom Kernel - Genevn")
        self.assertEqual(build_job["runs-on"], "ubuntu-22.04")

    def test_free_disk_space_step_removed(self):
        # An earlier revision ran endersonmenezes/free-disk-space before
        # checkout; it was dropped in this revision.
        steps = self.jobs["build"]["steps"]
        for step in steps:
            self.assertNotEqual(step.get("uses", ""), "endersonmenezes/free-disk-space@v3")

    def test_no_leftover_device_profile_or_parse_references(self):
        # The whole "Parse Target Profile Details" step (and its backing
        # device-profiles.json / steps.parse.outputs.* expressions) was
        # removed. Nothing in the file should reference them any more.
        self.assertNotIn("device-profiles.json", self.raw)
        self.assertNotIn("steps.parse.outputs", self.raw)
        self.assertNotIn("kernel_target", self.raw)
        step_names = [step.get("name") for step in self.jobs["build"]["steps"]]
        self.assertNotIn("Parse Target Profile Details", step_names)


class GenevnGWorkflowStepsTest(unittest.TestCase):
    """Detailed tests for each build step, in order."""

    EXPECTED_STEP_NAMES = [
        "Checkout Code",
        "Install Toolchain",
        "Clone Kernel Source",
        "Merge Configs & Apply Features",
        "Build Kernel",
        "Package Kernel",
        "Upload Artifact",
    ]

    @classmethod
    def setUpClass(cls):
        cls.raw, cls.workflow = _load_workflow(WORKFLOW_PATH)
        cls.steps = cls.workflow["jobs"]["build"]["steps"]
        cls.steps_by_name = {step.get("name"): step for step in cls.steps}

    def test_step_names_and_order(self):
        self.assertEqual(
            [step.get("name") for step in self.steps], self.EXPECTED_STEP_NAMES
        )

    def test_step_names_are_unique(self):
        names = [step.get("name") for step in self.steps]
        self.assertEqual(len(names), len(set(names)))

    def test_step_count(self):
        self.assertEqual(len(self.steps), len(self.EXPECTED_STEP_NAMES))

    def test_checkout_code_step(self):
        step = self.steps_by_name["Checkout Code"]
        self.assertEqual(step["uses"], "actions/checkout@v4")
        self.assertNotIn("run", step)

    def test_install_toolchain_step_installs_expected_packages(self):
        step = self.steps_by_name["Install Toolchain"]
        run = step["run"]
        self.assertIn("sudo apt-get update", run)
        for pkg in (
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
            self.assertIn(pkg, run)

    def test_install_toolchain_step_no_longer_installs_nodejs(self):
        # The nodesource/Node.js bootstrap lines were removed.
        step = self.steps_by_name["Install Toolchain"]
        run = step["run"]
        self.assertNotIn("nodesource", run)
        self.assertNotIn("nodejs", run)

    def test_install_toolchain_step_drops_unused_packages(self):
        # Packages that were only needed for the removed device-profile
        # parsing / kpm / dtb tooling should no longer be installed.
        step = self.steps_by_name["Install Toolchain"]
        run = step["run"]
        for pkg in ("jq", "device-tree-compiler", "kmod", "python3", "cpio"):
            self.assertNotIn(pkg, run)

    def test_clone_kernel_source_step_content(self):
        step = self.steps_by_name["Clone Kernel Source"]
        run = step["run"]
        self.assertIn(
            "git clone --depth=1 -b android-14-release https://github.com kernel-msm-1",
            run,
        )
        self.assertIn("cd kernel-msm-1", run)
        self.assertIn("git clone --depth=1 https://googlesource.com common", run)

    def test_clone_kernel_source_step_has_two_clone_commands(self):
        step = self.steps_by_name["Clone Kernel Source"]
        run = step["run"]
        self.assertEqual(run.count("git clone"), 2)

    def test_merge_configs_step_has_no_env_block(self):
        # The previous revision threaded all six feature-toggle inputs
        # through an `env:` block on this step; that block, and the
        # dynamic CONFIG_LIST it built, are both gone.
        step = self.steps_by_name["Merge Configs & Apply Features"]
        self.assertNotIn("env", step)

    def test_merge_configs_step_uses_hardcoded_config_paths(self):
        step = self.steps_by_name["Merge Configs & Apply Features"]
        run = step["run"]
        self.assertIn("export ARCH=arm64", run)
        self.assertIn("./scripts/kconfig/merge_config.sh -O out", run)
        self.assertIn("arch/arm64/configs/vendor/parrot_GKI.config", run)
        self.assertIn("arch/arm64/configs/ksu-nh.defconfig", run)
        self.assertIn("make O=out olddefconfig", run)

    def test_merge_configs_step_does_not_reference_removed_toggles(self):
        step = self.steps_by_name["Merge Configs & Apply Features"]
        run = step["run"]
        for removed_ref in (
            "ADD_ZEROMOUNT",
            "ADD_BBG",
            "ADD_KPM",
            "KSU_VARIANT",
            "CONFIG_LIST",
        ):
            self.assertNotIn(removed_ref, run)

    def test_build_kernel_step_content(self):
        step = self.steps_by_name["Build Kernel"]
        run = step["run"]
        self.assertIn("cd kernel-msm-1", run)
        self.assertIn("export ARCH=arm64", run)
        self.assertIn("export LLVM=1", run)
        self.assertIn(
            "make O=out ARCH=arm64 CC=clang-12 Image.gz -j$(nproc --all)", run
        )

    def test_build_kernel_step_drops_extra_toolchain_exports(self):
        # CROSS_COMPILE / LLVM_IAS / explicit LD-AR-NM-OBJCOPY exports and
        # the hard-coded KBUILD_BUILD_USER/HOST/LOCALVERSION values were
        # all removed in favor of the minimal build invocation above.
        step = self.steps_by_name["Build Kernel"]
        run = step["run"]
        for removed_ref in (
            "CROSS_COMPILE",
            "LLVM_IAS",
            "KBUILD_BUILD_USER",
            "KBUILD_BUILD_HOST",
            "LOCALVERSION",
            "|| exit 1",
        ):
            self.assertNotIn(removed_ref, run)

    def test_package_kernel_step_content(self):
        step = self.steps_by_name["Package Kernel"]
        # The step name no longer contains the mojibake
        # "Package Kernel via Personal AnyKernel纯包" text from before.
        self.assertEqual(step["name"], "Package Kernel")
        run = step["run"]
        self.assertIn(
            "git clone --depth=1 https://github.com anykernel-workspace", run
        )
        self.assertIn(
            "cp kernel-msm-1/out/arch/arm64/boot/Image.gz anykernel-workspace/", run
        )
        self.assertIn("cd anykernel-workspace", run)
        self.assertIn("zip -r9 ../Genevn-Kernel-Flashable.zip *", run)

    def test_package_kernel_step_drops_git_rm_and_015stray91_repo(self):
        step = self.steps_by_name["Package Kernel"]
        run = step["run"]
        self.assertNotIn("015stray91", run)
        self.assertNotIn("rm -rf anykernel-workspace/.git", run)

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

    def test_upload_artifact_step_drops_extra_options(self):
        # compression-level and overwrite were both removed from `with:`.
        step = self.steps_by_name["Upload Artifact"]
        self.assertNotIn("compression-level", step["with"])
        self.assertNotIn("overwrite", step["with"])


if __name__ == "__main__":
    unittest.main()