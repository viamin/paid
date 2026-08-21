---
parent: PAID
prefix: EXEC-INGRESS
---

# EARS Specs: Execution Ingress

> Testable claims for execution-environment inbound exposure.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **EXEC-INGRESS-001** — The execution run contract SHALL make the default
  ingress posture explicit as no public inbound endpoint, and runner/pre-
  provision validation SHALL reject unsupported inbound exposure requests
  before workload provisioning begins.
  *Tests:* `spec/services/execution_runners_spec.rb`,
  `spec/services/execution_runners/local_docker_runner_spec.rb`,
  `spec/services/containers/provision_spec.rb`
  *Code:* `ExecutionRunners::IngressPolicy`,
  `ExecutionRunners::RunSpec`,
  `ExecutionRunners::LocalDockerRunner`,
  `Containers::Provision.compatibility_for`

- [x] **EXEC-INGRESS-002** — Live preview exposure SHALL be represented as an
  explicit scoped ingress capability with expiration, authentication
  requirements, and grant metadata. The preview exception SHALL remain mediated
  by Paid's tunnel + Rails proxy path and SHALL NOT make the whole execution
  environment publicly reachable. Unsupported `debug` or `callback` exposure
  SHALL fail closed in production.
  *Tests:* `spec/jobs/preview_sessions/provision_job_spec.rb`,
  `spec/services/execution_runners_spec.rb`,
  `spec/services/execution_runners/local_docker_runner_spec.rb`
  *Code:* `AgentRun`,
  `PreviewSessions::ProvisionJob`,
  `Previews::Lifecycle`,
  `ExecutionRunners::IngressCapability`,
  `ExecutionRunners::IngressPolicy`
