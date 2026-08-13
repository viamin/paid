# Reference Architectures

## Managed cloud reference architecture

- Run a Paid-operated control plane with tenant isolation enforced through account scoping, row-level security, and isolated execution workspaces.
- Provide managed PostgreSQL, Redis, and object storage with routine backups, monitoring, and platform-led upgrades.
- Expose customer access through standard SaaS endpoints while keeping operator access behind hardened administrative controls and audit logging.

## Private SaaS reference architecture

- Provision a dedicated single-tenant stack per customer with isolated Rails, worker, database, cache, and object-storage resources.
- Restrict ingress through private connectivity, IP allowlists, or customer-approved identity-aware access paths.
- Keep Paid responsible for patching, upgrades, backup verification, and production monitoring while preserving customer-specific network and residency controls.

## Bring-your-own-cloud reference architecture

- Deploy Paid into the customer's cloud account using validated reference stacks such as `aws-terraform-v1`, `azure-aks-v1`, or `gcp-gke-v1`.
- Keep network boundaries, persistence services, and runtime identities inside customer-owned cloud resources while preserving the same application behavior as managed offerings.
- Re-validate automation, upgrades, rollback steps, and managed-service dependencies whenever the approved reference stack changes.
