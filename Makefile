SHELL := /usr/bin/env bash

CHECK_TYPES ?= profile jitter hessian hessian-merge retro selftest
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
KFLOW_INPUT_JOBS ?=
FLOW_GROUP ?= bet-2026-checks
JOB_TITLE ?=
JOB_DESCRIPTION ?=
KFLOW_PARALLEL_UNITS ?= true
JITTER_SEEDS ?=
JITTER_SEED ?=
RETRO_PEELS ?=
RETRO_PEEL ?=
SELFTEST_REPS ?=
SELFTEST_REP ?=
PROFILE_VALUES ?=
PROFILE_NAME ?=
MFK_SCALAR ?=
HESSIAN_NSPLIT ?=
HESSIAN_PARTS ?=
HESSIAN_PART ?=
NSPLIT ?=

export JITTER_SEEDS JITTER_SEED RETRO_PEELS RETRO_PEEL SELFTEST_REPS SELFTEST_REP
export PROFILE_VALUES PROFILE_NAME MFK_SCALAR HESSIAN_NSPLIT HESSIAN_PARTS HESSIAN_PART NSPLIT

.PHONY: help local clean kflow-register kflow kflow-batch

help:
	@printf '%s\n' \
	  'BET 2026 MFCL checks' \
	  '' \
	  'make kflow-register' \
	  '  Register profile, jitter, hessian, hessian-merge, retro, and selftest Kflow tasks.' \
	  '' \
	  'make kflow CHECK_TYPE=jitter MODEL_SELECTOR=08-RegionalCPUE KFLOW_INPUT_JOBS=603' \
	  '  Submit one independent check job.' \
	  '' \
	  'make kflow-batch CHECK_TYPES="jitter retro hessian" MODEL_SELECTORS="08-RegionalCPUE 15-DataWeighting" KFLOW_INPUT_JOBS=603' \
	  '  Submit check x model jobs; seed/peel/rep/profile/hessian units split by default.' \
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
	rm -rf outputs work profile/outputs profile/work jitter/outputs jitter/work hessian/outputs hessian/work hessian-merge/outputs hessian-merge/work retro/outputs retro/work selftest/outputs selftest/work .R-library .kflow-runtime-cache .docker-home

kflow-register:
	@test -n "$${KFLOW_API_TOKEN:-}" || { echo 'Set KFLOW_API_TOKEN before running make kflow-register.' >&2; exit 2; }
	@for check in $(CHECK_TYPES); do \
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
	  --parallel-units '$(KFLOW_PARALLEL_UNITS)' \
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
	  --parallel-units '$(KFLOW_PARALLEL_UNITS)' \
	  --job-title '$(JOB_TITLE)' \
	  --job-description '$(JOB_DESCRIPTION)'
