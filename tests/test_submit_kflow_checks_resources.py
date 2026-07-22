from __future__ import annotations

import ast
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "submit_kflow_checks.py"
PROFILE_MERGE_TASK = Path(__file__).resolve().parents[1] / "profile-merge" / "kflow.yaml"


class SubmitKflowCheckResourceTests(unittest.TestCase):
    def test_parallel_checks_share_production_resource_defaults(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        tree = ast.parse(source)
        constants: dict[str, str] = {}
        for node in tree.body:
            if not isinstance(node, ast.Assign) or len(node.targets) != 1:
                continue
            target = node.targets[0]
            if isinstance(target, ast.Name) and isinstance(node.value, ast.Constant):
                constants[target.id] = str(node.value.value)

        self.assertEqual(constants["DEFAULT_CHECK_CPUS"], "2")
        self.assertEqual(constants["DEFAULT_CHECK_MEMORY"], "8GB")
        self.assertEqual(constants["DEFAULT_CHECK_DISK"], "10GB")
        self.assertEqual(constants["DEFAULT_PROFILE_CPUS"], "1")
        self.assertEqual(constants["DEFAULT_PROFILE_MEMORY"], "8GB")
        self.assertEqual(constants["DEFAULT_PROFILE_MERGE_CPUS"], "1")
        self.assertEqual(constants["DEFAULT_PROFILE_MERGE_MEMORY"], "4GB")
        self.assertEqual(constants["DEFAULT_PROFILE_HBASE_MERGE_CPUS"], "2")
        self.assertEqual(constants["DEFAULT_PROFILE_HBASE_MERGE_MEMORY"], "16GB")
        self.assertEqual(constants["DEFAULT_PROFILE_REPAIR_CPUS"], "2")
        self.assertEqual(constants["DEFAULT_PROFILE_REPAIR_MEMORY_GB"], "16")
        self.assertEqual(constants["DEFAULT_PROFILE_REPAIR_MEMORY_PER_WORKER_GB"], "8")
        self.assertEqual(constants["SUVA_HOST"], "suvofpsubmit.corp.spc.int")
        self.assertEqual(constants["SUVA_USER"], "kyuhank")
        self.assertEqual(constants["SUVA_BASE_DIR"], "/home/kyuhank/KflowOutput")
        self.assertIn('os.environ.get("KFLOW_CPUS", DEFAULT_CHECK_CPUS)', source)
        self.assertIn('os.environ.get("KFLOW_MEMORY", DEFAULT_CHECK_MEMORY)', source)
        self.assertIn('os.environ.get("KFLOW_DISK", DEFAULT_CHECK_DISK)', source)
        self.assertIn('**check_task_resources(check, submitter_fields)', source)
        self.assertIn('**check_task_resources(merge_check, submitter_fields)', source)
        self.assertIn('os.environ.get("KFLOW_REMOTE_HOST", SUVA_HOST)', source)
        self.assertIn('"slot_requirements": args.slot_requirements', source)

    def test_profile_merge_uses_lightweight_repair_resources(self) -> None:
        source = PROFILE_MERGE_TASK.read_text(encoding="utf-8")
        resources = source.split("resources:\n", 1)[1].split("env:\n", 1)[0]

        self.assertIn("  cpus: 1\n", resources)
        self.assertIn("  memory: 4GB\n", resources)
        self.assertNotIn("  cpus: 4\n", resources)
        self.assertNotIn("  memory: 32GB\n", resources)
        self.assertIn('PROFILE_POST_MERGE_REPAIR: "false"', source)
        self.assertIn('PROFILE_REPAIR_CPUS: "1"', source)
        self.assertIn('PROFILE_REPAIR_MEMORY_GB: "4"', source)
        self.assertIn('PROFILE_REPAIR_MEMORY_PER_WORKER_GB: "4"', source)


if __name__ == "__main__":
    unittest.main()
