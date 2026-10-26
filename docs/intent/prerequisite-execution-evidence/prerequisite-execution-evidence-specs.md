# EARS Specs: Prerequisite Execution Evidence

- [x] **PREREQUISITE-EVIDENCE-001**: When an operator starts or resumes a
      prerequisite execution validation, the system shall inspect the selected
      execution runner's capabilities and current backend readiness before any
      provisioning attempt, and shall record `unavailable` with the exact
      backend remediation when no compatible isolated backend exists.

- [x] **PREREQUISITE-EVIDENCE-002**: When a compatible backend is available,
      the system shall provision the persisted AgentRun, execute the selected
      native analyzer and authorized sidecar interaction only through
      `execute_in_execution_environment`, and durably retain the pinned run,
      image, checkout, endpoint, stdout, stderr, exit-status, and cleanup
      receipt.

- [x] **PREREQUISITE-EVIDENCE-003**: When a required rollout flag or allowed
      image is unavailable, the system shall not provision the sidecar or
      alter policy; it shall retain an unavailable receipt that names the
      required scoped authorization or image-allowlist action.

- [x] **PREREQUISITE-EVIDENCE-004**: When a validation is cancelled, fails,
      or is retried, the system shall preserve prior evidence, perform normal
      cleanup, revalidate current capabilities and policy on the next request,
      and reuse a successful current receipt without re-executing it.
