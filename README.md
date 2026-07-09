# BET 2026 MFCL checks

<p align="right">
  <a href="#kflow"><img src="kflow-ready.svg" alt="Kflow ready checks"></a>
</p>

Kflow tasks for running `mfclkit` diagnostics on fitted MFCL model outputs:

- `profile`
- `jitter`
- `hessian`
- `retro`
- `selftest`
- `aspm`

The tasks are intentionally model-output driven, not stepwise-specific. A run can
consume either:

1. a full MFCL case directory with `.frq` and a fitted `.par`, or
2. a compact output directory with `final.par` plus a `model-index.csv` row that
   identifies the original source case path.

This means outputs from stepwise, sensitivity, or later BET model workflows can
all feed the same checks as long as they expose the same contract.

## Common Kflow fields

- `MODEL_SELECTOR`: model key to pick from the input artifact. It can match
  `step_id`, `model_label`, `job_key`, directory basename, or `model_source`.
- `MODEL_SOURCE_REPO`: GitHub repo used to reconstruct compact outputs, for
  example `PacificCommunity/ofp-sam-bet-2026-stepwise`.
- `MODEL_SOURCE_REF`: branch, tag, or commit for `MODEL_SOURCE_REPO`.
- `MODEL_SOURCE_PATH`: optional source case override. If unset, the selected
  `model-index.csv` row supplies `model_source`.
- `PROGRAM_PATH`: MFCL executable path inside the Docker image.
- `CHECK_START_PAR_NAME`: staged start par filename. Default is `final.par`.
- `CHECK_DRY_RUN`: set `true` for a fast smoke test that stages the model and
  exits before running MFCL.
- `CHECK_BUILD_REPORT_FIGURES`: build mfclshiny report-ready figures after the
  check. Default is `true`.
- `CHECK_REPORT_FIGURE_KEYS`: optional comma/space list of report-ready item keys
  such as `figure:jitter-diagnostics`. If unset, jitter/retro/selftest/aspm
  checks export only their matching diagnostic figures instead of the full app
  bundle.
- `CHECK_RENDER_REVIEW_HTML`: render a small HTML review for check figures.
  Default is `false`.

## Output contract

Each check writes one mfclshiny-compatible check folder:

```text
outputs/
  checks/<check_type>/<model_key>/
    model_payload.rds
    model_payload_manifest.{json,csv}
    check_manifest.{rds,csv}
    check-payload-index.csv
    jitter/ | retro/ | hessian/ | profile/ | selftest/ | aspm/
  checks/<check_type>/model-index.csv
  checks-index.csv
  report-ready-checks/<check_type>/<model_key>/
```

The copied `model_payload.rds` is the fitted parent model. The check-specific
subdirectories follow the structure mfclshiny already reads for likelihood
profiles, jitter, Hessian, retrospective, self-test, and ASPM diagnostics. This
lets a Kflow job open MFCL Shiny directly, and lets downstream results/report
jobs scan the same payload folders later without needing stepwise-specific
assumptions.

Each check or merge job also writes an updated model-run-style output:

```text
outputs/
  models/<model_key>/
    model_payload.rds
    model_payload_manifest.{json,csv}
    final.par
    jitter/ | retro/ | hessian/ | profile/ | selftest/ | aspm/
    attached-checks-index.{csv,rds}
  model-index.csv
  attached-checks-index.csv
  attached-model-bundle.{csv,rds}
```

This is the artifact results/report should consume. Original model-run archives
are not modified; each check/merge job produces a new model bundle with its
diagnostic folder attached. To accumulate checks, pass the previous updated
model bundle as the input to the next check or merge job. For example,
`jitter-merge` can write `outputs/models/<model>/jitter`, then a later
`retro-merge` can use that output as its input and add
`outputs/models/<model>/retro`.

When checks were run independently, use the `attach-checks` Kflow task to build
a final compact model bundle from one base model output plus completed check
outputs. Set `MODEL_BASE_INPUT_JOB` to the fitted model job, `CHECK_INPUT_JOBS`
to the completed check/merge jobs, and optionally `ATTACH_CHECK_TYPES` to limit
which diagnostic folders are copied.

## Check-specific fields

- `JITTER_SEEDS`: comma/space list of seeds, default `1`.
- `JITTER_CV`: jitter CV, default `0.2`.
- `JITTER_SLOTS`: optional comma/space list of `MFCLPar` slots to perturb. If
  unset, the runner uses a conservative set of continuous dev/coefficient slots
  and leaves structural, tag-reporting, maturity, movement, and fishery metadata
  untouched.
- `BET_JITTER_MAX_EVALS`: maximum evaluations for the final-phase jitter fit,
  default `5000`. Use a smaller value for quick smoke tests.
- `RETRO_PEELS`: comma/space list of peels, default `1`.
- `N_MIXING_PERIODS`: MFCL retrospective mixing periods, default `2`.
- `RETRO_USE_DOITALL`: use the staged `doitall.sh` when available. Default is
  `auto`.
- `RETRO_REMOVE_PAR_FILES`: remove copied `.par` files before a `doitall.sh`
  retro run. Default is `false`; enable only for model folders whose `doitall.sh`
  does not need staged par files.
- `RETRO_START_PAR_NAME`: when a `doitall.sh` run needs a conventional start
  par such as `00.par`, stage the fitted start par under this name if it is
  missing. Default is `00.par` for `doitall.sh` retro runs.
- `HESSIAN_NSPLIT`: number of Hessian parts, default `30`.
- `HESSIAN_PARTS`: comma/space list of Hessian parts. If unset, all parts are
  submitted as parallel Kflow jobs when parallel units are enabled.
- `PROFILE_TYPE`: `quantity` or `fixed_parameter`.
- `PROFILE_VALUES`: comma/space list of profile values.
- `PROFILE_PARALLEL_MODE`: profile jobs run as downstream/upstream chains when
  split for Kflow. Point-by-point scalar splitting is intentionally unsupported
  because each side should continue from the previous profile point.
- `PROFILE_CHAIN`: run profile values sequentially within a job. Default is
  `true`.
- `PROFILE_NAME`: profile folder name.
- `PROFILE_QUANTITY`: quantity profile target, for example `avg_bio` or
  `relative_depletion`.
- `PROFILE_BASE_QUANTITY`: optional fixed base quantity. If unset, mfclkit tries
  to read it from the staged fitted output.
- `PROFILE_APPLY_SCRIPT`: required for `PROFILE_TYPE=fixed_parameter`; this is a
  project-specific R script that edits copied MFCL inputs for each profile point.
- `SELFTEST_RUNNER`: optional override for native MFCL self-test. If unset,
  checks use the native self-test runner bundled with `mfclkit`.
- `SELFTEST_RUN_REFIT`: run self-test refits and write
  `selftest/refit/rep_*` outputs for mfclshiny. Default is `true`.
- `ASPM_MAX_EVALS`: maximum evaluations for the ASPM refit, default `10000`.
- `ASPM_FIX_SELECTIVITY`: fix selectivity to the fitted values before excluding
  composition data. Default is `true`.
- `ASPM_MIN_LF_SAMPLE_SIZE` and `ASPM_MIN_WF_SAMPLE_SIZE`: high minimum sample
  size controls used to exclude LF/WF composition influence. Defaults are
  `1000000`.
- `ASPM_EXTRA_SWITCH_LINES`: optional newline- or semicolon-separated MFCL
  control lines appended to the ASPM run. Use only for deliberate model-specific
  diagnostics.
- `CHECK_COMPACT_OUTPUTS`: keep check archives payload-first by removing raw
  MFCL case copies and intermediate files after the diagnostic payloads and logs
  have been written. Default is `true`.
- `CHECK_KEEP_RAW_OUTPUTS`: set to `true` for a one-off debugging run that needs
  every raw `.par`, `.rep`, `.frq`, and intermediate file in the Kflow archive.
  Default is `false`.
- `CHECK_ENRICH_PAYLOADS`: build compact mfclshiny payloads before raw outputs
  are removed. Default is `true`.
- `SELFTEST_COMPACT_CLEANUP`: compact self-test replicate folders in the
  mfclkit runner. Default is `1`.
- `SELFTEST_KEEP_MODEL_PAYLOAD`: keep full self-test truth/refit
  `model_payload.rds` files. Default is `0`; recovery tables and model-info
  payloads are kept either way.
- `HESSIAN_COMPACT`: compact Hessian part jobs while preserving the `.hes` files
  required by `hessian-merge`. Default is `true`.
- `HESSIAN_KEEP_MATRIX`: keep final merged Hessian matrix files in the
  `hessian-merge` archive. Default is `false`; Shiny/report diagnostics use
  `hessian_info.rds`.

## Local examples

```sh
MODEL_INPUT_ROOT=/path/to/job-output \
MODEL_SELECTOR=08-RegionalCPUE \
MODEL_SOURCE_REPO=PacificCommunity/ofp-sam-bet-2026-stepwise \
MODEL_SOURCE_REF=main \
bash run.sh jitter
```

```sh
CHECK_TYPE=profile \
PROFILE_TYPE=quantity \
PROFILE_NAME=adult_biomass \
PROFILE_QUANTITY=avg_bio \
PROFILE_VALUES="70 80 90 100 110 120 130" \
MODEL_INPUT_ROOT=/path/to/job-output \
MODEL_SELECTOR=15-DataWeighting \
bash run.sh
```

## Kflow

Register all check and merge tasks:

```sh
make kflow-register
```

Registered tasks include the same MFCL Shiny local app launcher used by the
stepwise/results jobs. Open it from the Kflow job page after a check job has an
output archive.

Launch independent jobs. Kflow/Condor will schedule the model checks in
parallel:

```sh
make kflow CHECK_TYPE=jitter MODEL_SELECTOR=08-RegionalCPUE KFLOW_INPUT_JOBS=596
make kflow-batch CHECK_TYPES="jitter retro hessian aspm" MODEL_SELECTORS="08-RegionalCPUE 15-DataWeighting" KFLOW_INPUT_JOBS="596 603"
```

For all 15 stepwise models, pass all 15 upstream model jobs and all 15
selectors. The submit helper creates one Kflow job for each check/model
combination, so Condor can schedule them in parallel.

Fast smoke test:

```sh
CHECK_DRY_RUN=true make kflow CHECK_TYPE=jitter MODEL_SELECTOR=04-NewStructure KFLOW_INPUT_JOBS=592
```
