# Reference Architectures

## Self-hosted reference architecture

- Deploy Paid Rails, PostgreSQL, Redis, and object storage inside a single tenant boundary.
- Terminate ingress at a managed reverse proxy or load balancer with TLS and IP allowlists.
- Run agent containers on dedicated worker hosts with isolated Docker storage and outbound egress controls.

## Private VPC reference architecture

- Place Paid web, worker, database, and cache tiers on private subnets with tightly scoped security groups.
- Expose operator access through VPN, bastion, or identity-aware proxy rather than broad public ingress.
- Prefer managed PostgreSQL, Redis, and object storage with customer-controlled network policies and backup retention.

## Air-gapped reference architecture

- Build release artifacts in a connected staging environment, then promote signed packages into the disconnected network.
- Mirror Ruby gems, Yarn packages, container images, and model/runtime dependencies into an approved offline registry.
- Validate restore, upgrade, and rollback procedures against the promoted artifact set before production rollout.
