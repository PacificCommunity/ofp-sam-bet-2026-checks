# BET 2026 MFCL checks

Kflow tasks for running `mfclkit` diagnostics on fitted MFCL model outputs:

- `profile`
- `jitter`
- `hessian`
- `retro`
- `selftest`

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

## Check-specific fields

- `JITTER_SEEDS`: comma/space list of seeds, default `1`.
- `JITTER_CV`: jitter CV, default `0.2`.
- `RETRO_PEELS`: comma/space list of peels, default `1`.
- `N_MIXING_PERIODS`: MFCL retrospective mixing periods, default `2`.
- `HESSIAN_NSPLIT`: number of Hessian parts, default `1`.
- `HESSIAN_PARTS`: comma/space list of Hessian parts. If unset, all parts are
  run in the same job.
- `PROFILE_TYPE`: `quantity` or `fixed_parameter`.
- `PROFILE_VALUES`: comma/space list of profile values.
- `PROFILE_NAME`: profile folder name.
- `PROFILE_QUANTITY`: quantity profile target, for example `avg_bio` or
  `relative_depletion`.
- `PROFILE_BASE_QUANTITY`: optional fixed base quantity. If unset, mfclkit tries
  to read it from the staged fitted output.
- `PROFILE_APPLY_SCRIPT`: required for `PROFILE_TYPE=fixed_parameter`; this is a
  project-specific R script that edits copied MFCL inputs for each profile point.
- `SELFTEST_RUNNER`: required for native MFCL self-test.

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

Register all five tasks:

```sh
make kflow-register
```

Launch independent jobs. Kflow/Condor will schedule the model checks in
parallel:

```sh
make kflow CHECK_TYPE=jitter MODEL_SELECTOR=08-RegionalCPUE KFLOW_INPUT_JOBS=596
make kflow-batch CHECK_TYPES="jitter retro hessian" MODEL_SELECTORS="08-RegionalCPUE 15-DataWeighting" KFLOW_INPUT_JOBS="596 603"
```

For all 15 stepwise models, pass all 15 upstream model jobs and all 15
selectors. The submit helper creates one Kflow job for each check/model
combination, so Condor can schedule them in parallel.

Fast smoke test:

```sh
CHECK_DRY_RUN=true make kflow CHECK_TYPE=jitter MODEL_SELECTOR=04-NewStructure KFLOW_INPUT_JOBS=592
```
