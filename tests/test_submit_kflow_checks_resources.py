from __future__ import annotations

import ast
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "submit_kflow_checks.py"


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
        self.assertIn('os.environ.get("KFLOW_CPUS", DEFAULT_CHECK_CPUS)', source)
        self.assertIn('os.environ.get("KFLOW_MEMORY", DEFAULT_CHECK_MEMORY)', source)
        self.assertIn('os.environ.get("KFLOW_DISK", DEFAULT_CHECK_DISK)', source)


if __name__ == "__main__":
    unittest.main()
