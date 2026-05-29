# Operational Assurance Runbooks

## Backup and Restore

1. Verify the configured backup cadence for PostgreSQL, Redis, and object storage.
2. Capture the most recent successful backup verification date in the compliance dashboard.
3. Rehearse a restore into a clean environment at least quarterly and record the restore validation date.
4. Confirm observed recovery time stays within the documented RTO and recovery point stays within the documented RPO.

## Upgrade Validation

1. Assign each tenant to an upgrade channel (`stable`, `extended_support`, or `preview`) and record the declared version-support policy.
2. Stage the target Paid release in a non-production environment that matches the production topology.
3. Run migrations, smoke tests, and critical account workflows before approving production rollout.
4. Document rollback prerequisites plus the production maintenance window before the change is scheduled.
5. Record the last validated upgrade date in the compliance dashboard after the rehearsal completes.

## Secret Rotation

1. Rotate customer-managed keys and provider credentials on the tenant-defined interval or after personnel/incident triggers.
2. Update the compliance dashboard with the KMS provider, key reference, and most recent key rotation date.
3. Record the operator owner and most recent secret rotation workflow completion date.
4. Export a compliance evidence pack after each rotation cycle for audit review.

## BYOC Reference Stack Validation

1. Identify the approved customer-cloud reference stack and the owning cloud provider for the tenant.
2. Re-run deployment automation in a clean validation environment whenever the stack definition or managed dependencies change.
3. Verify monitoring, backups, restore paths, and upgrade rollout behavior against the validated stack.
4. Record the reference stack identifier and most recent validation date in the compliance dashboard.
