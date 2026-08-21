# EARS Specs: Execution Authority Grants

- [x] **EXECUTION-AUTHORITY-001** — Before provisioning a fresh agent-run
  environment, the system SHALL derive a secret-free authority grant object for
  the run and SHALL persist it on the run record.
  *Tests:* `spec/models/agent_run_spec.rb`
  *Code:* `AgentRun#execution_authority_grants`,
  `AgentRun#persist_execution_authority_grants!`

- [x] **EXECUTION-AUTHORITY-002** — The runner-facing execution contract SHALL
  expose the authority grant object without secret values so runner
  implementations can inspect grant classes and delivery modes before
  provisioning.
  *Tests:* `spec/services/execution_runners_spec.rb`
  *Code:* `ExecutionRunners::AuthorityGrantSet`,
  `ExecutionRunners::ExecutionInputManifest`

- [x] **EXECUTION-AUTHORITY-003** — Model-provider grants SHALL distinguish
  proxy-mode, subscription-auth, and direct-outbound execution, and
  subscription-auth runs SHALL separately expose subscription-auth material.
  *Tests:* `spec/services/execution_runners_spec.rb`
  *Code:* `ExecutionRunners::AuthorityGrantSet`

- [x] **EXECUTION-AUTHORITY-004** — Runs with MCP-attached servers, durable
  artifact upload authority, or service-env credentials SHALL expose those
  authority classes without persisting secret payloads.
  *Tests:* `spec/services/execution_runners_spec.rb`
  *Code:* `ExecutionRunners::AuthorityGrantSet`
