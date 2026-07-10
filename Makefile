SHELL := /usr/bin/env bash

CHECK_TYPES ?= profile jitter hessian retro selftest aspm
KFLOW_REGISTER_CHECK_TYPES ?= profile jitter hessian hessian-merge jitter-merge profile-merge retro-merge selftest-merge retro selftest aspm aspm-merge attach-checks model-bundle
CHECK_TYPE ?= jitter
MODEL_SELECTOR ?=
MODEL_SELECTORS ?= $(MODEL_SELECTOR)
MODEL_SOURCE_REPO ?= PacificCommunity/ofp-sam-bet-2026-stepwise
MODEL_SOURCE_REF ?= main
MODEL_SOURCE_PATH ?=
MODEL_INPUT_ROOT ?=
PROGRAM_PATH ?= /home/mfcl/mfclo64
KFLOW_URL ?= http://127.0.0.1:8089
KFLOW_TASK_PREFIX ?= ofp-sam-bet-2026-check
KFLOW_SUBMITTER ?=
KFLOW_REMOTE_HOST ?=
KFLOW_REMOTE_USER ?=
KFLOW_REMOTE_BASE_DIR ?=
KFLOW_INPUT_JOBS ?=
FLOW_GROUP ?= bet-2026-checks
JOB_TITLE ?=
JOB_DESCRIPTION ?=
KFLOW_PARALLEL_UNITS ?= true
KFLOW_AUTO_MERGE ?= true
JITTER_SEEDS ?=
JITTER_SEED ?=
RETRO_PEELS ?=
RETRO_PEEL ?=
RETRO_MAKEPAR_START ?=
RETRO_REMOVE_PAR_FILES ?=
RETRO_START_PAR_NAME ?=
SELFTEST_REPS ?=
SELFTEST_REP ?=
PROFILE_VALUES ?=
PROFILE_NAME ?=
PROFILE_PARALLEL_MODE ?= chains
PROFILE_CENTER ?=
PROFILE_CHAIN ?= true
PROFILE_CHAIN_SIDE ?=
MFK_SCALAR ?=
HESSIAN_NSPLIT ?= 30
HESSIAN_PARTS ?=
HESSIAN_PART ?=
NSPLIT ?=
ASPM_MAX_EVALS ?=
ASPM_FIX_SELECTIVITY ?=
ASPM_MIN_LF_SAMPLE_SIZE ?=
ASPM_MIN_WF_SAMPLE_SIZE ?=
ASPM_EXTRA_SWITCH_LINES ?=
BUNDLE_NAME ?=
BUNDLE_FRQ ?=
BUNDLE_FINAL_PAR_NAME ?= 11.par
BUNDLE_REPORT_OUTPUT_PAR ?= report.par
BUNDLE_REPORT_SWITCHES ?=
BUNDLE_GENERATE_REPORTS ?= true
BUNDLE_REQUIRE_PLOT_REP ?= true
BUNDLE_ALLOW_REPORT_FAILURE ?= false
BUNDLE_INCLUDE_EXE ?= true
BUNDLE_EXE_NAME ?= mfclo64
BUNDLE_VERIFY_ZIP_RUN ?= true
BUNDLE_DROP_STAGED_FINAL_PAR ?= true
TRIGGER_NEXT ?=

export JITTER_SEEDS JITTER_SEED RETRO_PEELS RETRO_PEEL RETRO_MAKEPAR_START RETRO_REMOVE_PAR_FILES RETRO_START_PAR_NAME SELFTEST_REPS SELFTEST_REP
export PROFILE_VALUES PROFILE_NAME PROFILE_PARALLEL_MODE PROFILE_CENTER PROFILE_CHAIN PROFILE_CHAIN_SIDE MFK_SCALAR
export HESSIAN_NSPLIT HESSIAN_PARTS HESSIAN_PART NSPLIT
export ASPM_MAX_EVALS ASPM_FIX_SELECTIVITY ASPM_MIN_LF_SAMPLE_SIZE ASPM_MIN_WF_SAMPLE_SIZE ASPM_EXTRA_SWITCH_LINES
export BUNDLE_NAME BUNDLE_FRQ BUNDLE_FINAL_PAR_NAME BUNDLE_REPORT_OUTPUT_PAR BUNDLE_REPORT_SWITCHES BUNDLE_GENERATE_REPORTS BUNDLE_REQUIRE_PLOT_REP BUNDLE_ALLOW_REPORT_FAILURE BUNDLE_INCLUDE_EXE BUNDLE_EXE_NAME BUNDLE_VERIFY_ZIP_RUN BUNDLE_DROP_STAGED_FINAL_PAR
export TRIGGER_NEXT

.PHONY: help local clean kflow-register kflow kflow-batch

help:
	@printf '%s\n' \
	  'BET 2026 MFCL checks' \
	  '' \
	  'make kflow-register' \
	  '  Register profile, jitter, hessian, retro, selftest, aspm, and merge Kflow tasks.' \
	  '' \
	  'make kflow CHECK_TYPE=jitter MODEL_SELECTOR=08-RegionalCPUE KFLOW_INPUT_JOBS=603' \
	  '  Submit one independent check job.' \
	  '' \
	  'make kflow-batch CHECK_TYPES="jitter retro hessian aspm" MODEL_SELECTORS="08-RegionalCPUE 15-DataWeighting" KFLOW_INPUT_JOBS=603' \
	  '  Submit check x model jobs; seed/peel/rep/hessian units split by default; profile splits into downstream/upstream chains.' \
	  '' \
	  'make kflow CHECK_TYPE=model-bundle MODEL_SELECTOR=12-OrthogonalPoly KFLOW_INPUT_JOBS=1926 KFLOW_AUTO_MERGE=false KFLOW_AUTO_ATTACH=false' \
	  '  Create a portable MFCL run bundle zip for a fitted model job.' \
	  '' \
	  'KFLOW_PARALLEL_UNITS=false make kflow CHECK_TYPE=jitter JITTER_SEEDS="1 2 3"' \
	  '  Keep multiple check units in one Kflow job instead of splitting them.' \
	  '' \
	  'make local CHECK_TYPE=jitter MODEL_INPUT_ROOT=/path/to/output MODEL_SELECTOR=08-RegionalCPUE'

local:
	CHECK_TYPE='$(CHECK_TYPE)' \
	MODEL_SELECTOR='$(MODEL_SELECTOR)' \
	MODEL_SOURCE_REPO='$(MODEL_SOURCE_REPO)' \
	MODEL_SOURCE_REF='$(MODEL_SOURCE_REF)' \
	MODEL_SOURCE_PATH='$(MODEL_SOURCE_PATH)' \
	MODEL_INPUT_ROOT='$(MODEL_INPUT_ROOT)' \
	PROGRAM_PATH='$(PROGRAM_PATH)' \
	bash run.sh '$(CHECK_TYPE)'

clean:
	rm -rf outputs work profile/outputs profile/work jitter/outputs jitter/work hessian/outputs hessian/work hessian-merge/outputs hessian-merge/work jitter-merge/outputs jitter-merge/work profile-merge/outputs profile-merge/work retro-merge/outputs retro-merge/work selftest-merge/outputs selftest-merge/work retro/outputs retro/work selftest/outputs selftest/work aspm/outputs aspm/work attach-checks/outputs attach-checks/work model-bundle/outputs model-bundle/work .R-library .kflow-runtime-cache .docker-home

kflow-register:
	@test -n "$${KFLOW_API_TOKEN:-}" || { echo 'Set KFLOW_API_TOKEN before running make kflow-register.' >&2; exit 2; }
	@for check in $(KFLOW_REGISTER_CHECK_TYPES); do \
	  python3 scripts/register_kflow_task.py --repo-root . --config "$$check/kflow.yaml" --kflow-url '$(KFLOW_URL)'; \
	done

kflow:
	@test -n "$${KFLOW_API_TOKEN:-}" || { echo 'Set KFLOW_API_TOKEN before running make kflow.' >&2; exit 2; }
	python3 scripts/submit_kflow_checks.py \
	  --kflow-url '$(KFLOW_URL)' \
	  --task-prefix '$(KFLOW_TASK_PREFIX)' \
	  --checks '$(CHECK_TYPE)' \
	  --models '$(MODEL_SELECTOR)' \
	  --input-jobs '$(KFLOW_INPUT_JOBS)' \
	  --flow-group '$(FLOW_GROUP)' \
	  --model-source-repo '$(MODEL_SOURCE_REPO)' \
	  --model-source-ref '$(MODEL_SOURCE_REF)' \
	  --model-source-path '$(MODEL_SOURCE_PATH)' \
	  --program-path '$(PROGRAM_PATH)' \
	  --submitter '$(KFLOW_SUBMITTER)' \
	  --remote-host '$(KFLOW_REMOTE_HOST)' \
	  --remote-user '$(KFLOW_REMOTE_USER)' \
	  --remote-base-dir '$(KFLOW_REMOTE_BASE_DIR)' \
	  --parallel-units '$(KFLOW_PARALLEL_UNITS)' \
	  --auto-merge '$(KFLOW_AUTO_MERGE)' \
	  --job-title '$(JOB_TITLE)' \
	  --job-description '$(JOB_DESCRIPTION)'

kflow-batch:
	@test -n "$${KFLOW_API_TOKEN:-}" || { echo 'Set KFLOW_API_TOKEN before running make kflow-batch.' >&2; exit 2; }
	python3 scripts/submit_kflow_checks.py \
	  --kflow-url '$(KFLOW_URL)' \
	  --task-prefix '$(KFLOW_TASK_PREFIX)' \
	  --checks '$(CHECK_TYPES)' \
	  --models '$(MODEL_SELECTORS)' \
	  --input-jobs '$(KFLOW_INPUT_JOBS)' \
	  --flow-group '$(FLOW_GROUP)' \
	  --model-source-repo '$(MODEL_SOURCE_REPO)' \
	  --model-source-ref '$(MODEL_SOURCE_REF)' \
	  --model-source-path '$(MODEL_SOURCE_PATH)' \
	  --program-path '$(PROGRAM_PATH)' \
	  --submitter '$(KFLOW_SUBMITTER)' \
	  --remote-host '$(KFLOW_REMOTE_HOST)' \
	  --remote-user '$(KFLOW_REMOTE_USER)' \
	  --remote-base-dir '$(KFLOW_REMOTE_BASE_DIR)' \
	  --parallel-units '$(KFLOW_PARALLEL_UNITS)' \
	  --auto-merge '$(KFLOW_AUTO_MERGE)' \
	  --job-title '$(JOB_TITLE)' \
	  --job-description '$(JOB_DESCRIPTION)'
