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
- `model-bundle`

The registered Kflow tasks pin `mfclkit 0.0.0.9008` and
`mfclshiny 0.0.0.9007` by commit so reruns do not drift when either package's
`main` branch changes.
Both repositories are public, so diagnostic workers install the pinned sources
without forwarding a GitHub credential into the runtime container.

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

Each check or merge job can also write an updated model-run-style output. In
standalone-compatible `ATTACH_OUTPUT_MODE=full`, the output contains the full
base case:

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
diagnostic folder attached. Kflow launches diagnostic merges independently from
the same fitted base and composes their output overlays; merge jobs do not wait
for one another.

For Kflow attached outputs, `ATTACH_OUTPUT_MODE=delta` publishes a much smaller
overlay instead:

```text
outputs/
  models/<model_key>/
    model_payload.rds
    model_payload_manifest.{json,csv}
    <updated-check>/
    attached-checks-index.{csv,rds}
  model-index.csv
  attached-checks-index.csv
  attached-model-bundle.{csv,rds}
  attach-output-manifest.{csv,rds}
```

The full base case is used while rebuilding the payload, then `.frq`, `.ini`,
`.par`, `.rep`, fit files, and static maps are removed from the published delta.
Every diagnostic directory represented by an artifact's attached-checks index
is retained. Independent merge deltas intentionally index only their own
diagnostic; Kflow preserves sibling overlays during composition.
`attached-model-bundle.csv` records
`output_mode`, `overlay_base_required`, and the base job reference. Set
`ATTACH_OUTPUT_MODE=full` when the artifact must remain a standalone MFCL case.
The `attach-checks` Kflow task defaults to `full`, because a manual or legacy
submission cannot infer Kflow's overlay metadata from the environment after the
job has started. The submit helper opts independent diagnostic merges into
`delta` explicitly and supplies the matching Kflow metadata at submission.

When checks were run independently, use the `attach-checks` Kflow task to build
a final compact model bundle from one base model output plus completed check
outputs. Set `MODEL_BASE_INPUT_JOB` to the fitted model job, `CHECK_INPUT_JOBS`
to the completed check/merge jobs, and optionally `ATTACH_CHECK_TYPES` to limit
which diagnostic folders are copied.

Each existing diagnostic merge task (`hessian-merge`, `profile-merge`,
`jitter-merge`, `retro-merge`, `aspm-merge`, and `selftest-merge`) can also be
the collector for its own diagnostic; no common extra merge task is required.
Each merge is independent: it receives the original fitted model plus only its
own unit jobs, refreshes a current-type payload for direct inspection, and
publishes a delta containing only that diagnostic. Kflow composes those sibling
overlays on the original model and dynamically collects all overlaid diagnostic
directories. A failed or missing unit is retained as a status ledger instead of
being hidden or omitted.

The independent-merge environment contract is:

- `MODEL_BASE_INPUT_JOB` / `BASE_MODEL_JOB`: original fitted model job;
- `MODEL_ORIGINAL_BASE_INPUT_JOB`: the same original job that owns the overlay;
- `CHECK_INPUT_JOBS`: only the current diagnostic's unit jobs;
- `ATTACH_CHECK_TYPES`: the current merge diagnostic.

The original fitted job remains the single owner of `.frq`, `.ini`, `.par`,
reports, and other runnable/static files; independent deltas do not duplicate
them or claim diagnostics produced by sibling jobs.

With direct delta attachment enabled, each diagnostic merge is its own final
collector. The submit helper marks it with `attached_output_overlay=true` and
`attached_work_parent_job`, declares replaceable diagnostic names in
`attached_output_overlay_replace_names`, and adds the fitted base job to the
merge inputs. Each merge publishes its own diagnostic delta directly on the
base job without duplicating the raw base case or `outputs/checks/...` tree.

Use `model-bundle` when someone needs a portable MFCL run zip from an existing
model job. It restores the fitted par as `11.par`, copies the `mfclo64`
executable from the Kflow runtime, regenerates plot/report files, verifies the
zip by extracting it and running `./make-plot-rep.sh`, and writes
`outputs/model-bundles/<model>/<model>-mfcl-run-bundle.zip` with `.frq`, `.ini`,
`.tag`, `mfcl.cfg`, `doitall.sh`, `run-doitall.sh`, `11.par`, `plot.rep`,
`mfclo64`, and a manifest. The bundle keeps the final par under the doitall
step name, e.g. `11.par`, and drops the duplicate staged `final.par` by default.

```sh
make kflow CHECK_TYPE=model-bundle \
  MODEL_SELECTOR=12-OrthogonalPoly \
  KFLOW_INPUT_JOBS=1926 \
  MODEL_SOURCE_REPO=PacificCommunity/ofp-sam-bet-2026-stepwise \
  MODEL_SOURCE_REF=6226c5387d921290535512c79d8a92ff7e4addd3 \
  KFLOW_AUTO_MERGE=false KFLOW_AUTO_ATTACH=false
```

## Check-specific fields

- `FLOW_SPECIES`, `FLOW_SPECIES_LABEL`, and `FLOW_ASSESSMENT_YEAR`: optional
  input-driven report metadata. The submit helper forwards these values through
  unit, merge, and attach jobs so mfclshiny output is not tied to the BET 2026
  defaults used by this assessment repository.
- `ATTACH_OUTPUT_MODE`: `delta` publishes only the refreshed payload/index plus
  the current diagnostic folder for overlay on the base job; `full` preserves a
  standalone base-model bundle. Direct diagnostic merges use `delta`.
- `JITTER_SEEDS`: comma/space list of seeds, default `1`.
- `JITTER_CV`: jitter CV, default `0.2`.
- `JITTER_METHOD`: `phase1_doitall` by default. This builds a fresh
  `00.par`, runs the staged `doitall.sh` through PHASE1, jitters the resulting
  `01.par` starting values, then resumes the remaining phases. Use `simple` to
  run the older direct fitted-par jitter path.
- `JITTER_SLOTS`: optional comma/space list of `MFCLPar` slots to perturb. If
  unset, the runner uses a conservative set of continuous dev/coefficient slots
  and leaves structural metadata untouched. This is used by the `simple`
  method and as a conservative writer fallback.
- `JITTER_TAG_MIXING_FIX`: `auto` by default. The tag/ini mixing-period patch is
  applied only when the staged model has a `.tag` file.
- `JITTER_REQUIRE_INDEPVAR`: `true` by default. Native jitter uses MFCL's
  `indepvar.rpt` so only active independent variables are perturbed. Set it to
  `false` only as an explicit fallback for legacy cases without that report;
  the fallback perturbs the configured safe slots and records
  `jitter_parameter_scope=configured_slots_fallback` in the run result.
- `BET_JITTER_MAX_EVALS`: maximum evaluations for the final-phase jitter fit,
  default `5000`. This applies to `JITTER_METHOD=simple`.
- `RETRO_PEELS`: comma/space list of peels, default `1`.
- `N_MIXING_PERIODS`: MFCL retrospective mixing periods, default `2`.
- `RETRO_USE_DOITALL`: use the staged `doitall.sh` when available. Default is
  `auto`, which uses `doitall.sh` when the staged MFCL case provides one and
  otherwise falls back to a direct fitted-par peel.
- `RETRO_MAKEPAR_START`: build the retro start `.par` from the peeled `.frq`
  and `.ini` before a `doitall.sh` retro run. Default is `auto`, enabled when
  `RETRO_USE_DOITALL` is active.
- `RETRO_REMOVE_PAR_FILES`: remove copied `.par` files before a `doitall.sh`
  retro run. Default is `auto`, enabled when `RETRO_MAKEPAR_START` is active so
  stale fitted `.par` files do not conflict with peeled inputs.
- `RETRO_START_PAR_NAME`: when a `doitall.sh` run needs a conventional start
  par such as `00.par` or `02.par`, stage the fitted start par under this name
  if it is missing. Default is `auto` for `doitall.sh` retro runs, which uses
  the first input `.par` referenced by `doitall.sh`; direct warm-start runs
  resolve `auto` to `retro-start.par` instead of treating `auto` as a filename.
- `RETRO_REWRITE_PAR`: rewrite the fitted `.par` range for direct fitted-par
  retro runs. Default is `auto`, enabled only when `RETRO_USE_DOITALL=false`.
- `HESSIAN_NSPLIT`: number of Hessian parts, default `30`.
- `HESSIAN_PARTS`: comma/space list of Hessian parts. If unset, all parts are
  submitted as parallel Kflow jobs when parallel units are enabled.
- `CHECK_EXPECTED_UNIT_TYPE` and `CHECK_EXPECTED_UNITS`: merge-side unit ledger
  generated automatically from parallel or batched Kflow submissions for jitter
  seeds, retro peels, self-test replicates, and ASPM. Seed, peel, and replicate
  lists must contain positive 32-bit integers; they are canonicalized and
  deduplicated in input order before both execution and ledger generation.
  Expected units that publish no check manifest or diagnostic payload are
  retained as failed `missing` rows, and the merge is marked `incomplete`.
- `PROFILE_TYPE`: `quantity` or `fixed_parameter`.
- `PROFILE_VALUES`: comma/space list of profile values.
- `PROFILE_PRESET`: quantity-profile continuation preset. `three_stage`
  (the default task setting) uses penalties `1e5, 1e6, 1e7` and evaluations
  `50, 50, 2000`; `manual_7stage` follows the MFCL manual; `adaptive` retains
  the distance-scaled BET sensitivity schedule. `PROFILE_STYLE` remains a
  legacy alias (`bet` maps to `adaptive`; older three-stage aliases remain
  accepted for compatibility).
- `PROFILE_PENALTIES` and `PROFILE_RAMP_REPS`: optional explicit override for
  the selected preset. Their lengths must agree for three-stage/manual profiles.
- Each profile point stores the constrained fit separately from a one-run,
  same-target, zero-penalty likelihood harvest. It never uses target zero to
  "refresh" a profile result.
- `PROFILE_PARALLEL_MODE`: profile jobs run as downstream/upstream chains when
  split for Kflow. Point-by-point scalar splitting is intentionally unsupported
  because each side should continue from the previous profile point.
- `PROFILE_CENTER`: profile anchor scalar, default `100`. The center is the
  fitted base model and is not re-run as a profile unit; merge writes it once as
  the base-anchor point.
- `PROFILE_INCLUDE_BASE_ANCHOR`: include the fitted base model as the center
  profile point during merge. Default is `true`.
- `PROFILE_EXPECTED_VALUES`: full expected scalar set passed to the merge job.
  Missing points, failed convergence, and missed quantity targets are retained
  as failed rows; the merged profile is then `incomplete`, not silently shown
  as complete.
- `PROFILE_MAX_GRAD_THRESHOLD`: maximum gradient accepted for a constrained
  profile fit, default `0.001`. Reaching the requested quantity alone is not a
  convergence result; both this gradient test and the target-tolerance test
  must pass.
- `PROFILE_TARGET_REL_TOLERANCE`: relative target tolerance, default `0.001`.
  `PROFILE_RETRY_INVALID`, `PROFILE_RETRY_JAGGED`,
  `PROFILE_CONTINUATION_REPS`, and `PROFILE_JAGGED_TOLERANCE` control the
  selective retry policy.
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
- `selftest_update_tags` / `SELFTEST_UPDATE_TAGS`: `auto` by default. Tag
  pseudo-data are generated only when the staged MFCL case has a `.tag` file.
- `selftest_require_native_tags` / `SELFTEST_REQUIRE_NATIVE_TAGS`: `auto` by
  default. Native tag simulation output is required only when tag pseudo-data
  are enabled for a model that actually has tag inputs.
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
- Each merged Hessian always records compact eigenvalue diagnostics in
  `hessian_info.rds` and `check-summary.csv`: the legacy native
  `n_negative_eigenvalues` field (which means nonpositive, `<= 0`), plus
  separate strictly-negative, zero, and positive counts parsed from native
  `sorted eigenvectors`. The large raw eigenvector report can still be compacted
  safely after those factual counts have been saved.

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
PROFILE_PRESET=three_stage \
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
