# Runner Conformance Fixture

This fixture represents the minimal repository cloned by the runner conformance
suite.

- Entry point: `bin/conformance-task`
- Expected stdout token: `CONFORMANCE_OK`
- Expected artifact: `artifacts/conformance-result.json`
- LLM required: no

The workload is deterministic by design. It writes a fixed JSON payload and
prints a fixed token so runner implementations can be compared without model
variance.
