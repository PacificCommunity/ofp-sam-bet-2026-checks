# BET 2026 MFCL checks

<a id="common-kflow-fields"></a>
<a id="output-contract"></a>
<a id="check-specific-fields"></a>
<a id="local-examples"></a>
<a id="kflow"></a>

Diagnostic runners for fitted MFCL cases: likelihood profiles, jitter,
Hessian, retrospective analysis, self-test and ASPM. Bundle and payload tools
prepare portable model outputs for review.

Start with a complete case containing the fitted PAR, matching inputs,
`doitall.sh` and executable. A compact payload is usable only when its native
artifacts and original input recipe can be restored. This repository contains
the runners and tests; it does not archive the assessment fits.
The `attach-checks` Kflow task defaults to `full` output.
Base-fit rows are marked `is_base_fit_reference=TRUE`.

A dry run stages one case without executing MFCL:

```sh
MODEL_INPUT_ROOT=/absolute/path/to/fitted-case \
MODEL_SELECTOR=your-model-key \
CHECK_DRY_RUN=true bash run.sh jitter
```

See [inputs, check controls and output formats](docs/reproduction.md) for the
pinned runtime and full commands. Run the test suite with
`python3 -m unittest discover -s tests -p 'test_*.py' -v`.

Assessment results are published separately:
[Diagnostic](https://pacificcommunity.github.io/ofp-sam-bet-2026-diagnostic/bet-2026-diagnostic-report.html),
[jitter](https://pacificcommunity.github.io/ofp-sam-bet-2026-jitter/jitter-report.html),
[retrospective](https://pacificcommunity.github.io/ofp-sam-bet-2026-retrospective/retrospective-report.html)
and [self-test](https://pacificcommunity.github.io/ofp-sam-bet-2026-selftest/selftest-report.html).
