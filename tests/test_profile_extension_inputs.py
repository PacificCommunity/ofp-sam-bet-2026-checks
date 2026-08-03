import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / "R" / "model_output_adapter.R"


class ProfileExtensionInputTests(unittest.TestCase):
    def run_r(self, expression: str, *args: Path, check=True):
        return subprocess.run(
            ["Rscript", "-e", expression, *map(str, args)],
            cwd=ROOT,
            env=os.environ.copy(),
            text=True,
            capture_output=True,
            check=check,
        )

    def write_payload(self, path: Path, par: Path, scalar=75, converged=True):
        path.parent.mkdir(parents=True, exist_ok=True)
        expression = r'''
args <- commandArgs(trailingOnly = TRUE)
par_bytes <- readBin(args[[2L]], what = "raw", n = file.info(args[[2L]])$size)
saveRDS(list(
  scalar = as.numeric(args[[3L]]),
  profile = "total_average_biomass",
  reference_quantity = 959429.43150684936,
  obj_fun = 90844,
  max_grad = 0.0009,
  run_status = "completed",
  artifacts = list(files = list(par = list(
    bytes = par_bytes, compression = "none"
  ))),
  mfclkit = list(run_completed = TRUE, converged = args[[4L]] == "true")
), args[[1L]])
'''
        self.run_r(
            expression,
            path,
            par,
            Path(str(scalar)),
            Path("true" if converged else "false"),
        )

    def test_restores_one_deduplicated_completed_endpoint(self):
        par_bytes = textwrap.dedent(
            """\
            # profile endpoint fixture
            # Objective function value
            90844
            # The number of parameters
            1997
            """
        ).encode()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            par = root / "endpoint.par"
            par.write_bytes(par_bytes)
            relative = Path(
                "S0.90-F2-tau2-fixed/profile/total_average_biomass/"
                "scalar_75/profile_payload.rds"
            )
            first = root / "inputs/job1/outputs/checks/profile" / relative
            second = root / "inputs/job1/outputs/models" / relative
            self.write_payload(first, par)
            second.parent.mkdir(parents=True, exist_ok=True)
            second.write_bytes(first.read_bytes())
            dest = root / "work/profile-chain-start.par"
            result = root / "result.rds"

            expression = r'''
args <- commandArgs(trailingOnly = TRUE)
source(args[[1L]])
x <- restore_profile_chain_start_payload(
  input_root = args[[2L]], scalar = 75,
  profile_name = "total_average_biomass",
  selector = "S0.90-F2", dest = args[[3L]]
)
saveRDS(x, args[[4L]])
'''
            self.run_r(expression, ADAPTER, root / "inputs", dest, result)
            self.assertEqual(dest.read_bytes(), par_bytes)
            self.assertEqual(
                hashlib.md5(dest.read_bytes()).hexdigest(),
                hashlib.md5(par_bytes).hexdigest(),
            )

            verify = r'''
x <- readRDS(commandArgs(trailingOnly = TRUE)[[1L]])
stopifnot(
  identical(x$scalar, 75),
  isTRUE(all.equal(x$reference_quantity, 959429.43150684936)),
  file.exists(x$par)
)
'''
            self.run_r(verify, result)

    def test_rejects_nonconverged_endpoint(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            par = root / "endpoint.par"
            par.write_text(
                "# Objective function value\n90844\n"
                "# The number of parameters\n1997\n",
                encoding="utf-8",
            )
            payload = root / (
                "inputs/S0.90-F2-tau2-fixed/profile/total_average_biomass/"
                "scalar_75/profile_payload.rds"
            )
            self.write_payload(payload, par, converged=False)
            expression = r'''
args <- commandArgs(trailingOnly = TRUE)
source(args[[1L]])
restore_profile_chain_start_payload(
  input_root = args[[2L]], scalar = 75,
  profile_name = "total_average_biomass",
  selector = "S0.90-F2", dest = args[[3L]]
)
'''
            process = self.run_r(
                expression,
                ADAPTER,
                root / "inputs",
                root / "start.par",
                check=False,
            )
            self.assertNotEqual(process.returncode, 0)
            self.assertIn(
                "No completed, converged profile payload", process.stderr
            )


if __name__ == "__main__":
    unittest.main()
