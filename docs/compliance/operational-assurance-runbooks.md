# Operational Assurance Runbooks

## Backup and Restore

1. Verify the configured backup cadence for PostgreSQL, Redis, and object storage.
2. Capture the most recent successful backup verification date in the compliance dashboard.
3. Rehearse a restore into a clean environment at least quarterly and record the restore validation date.
4. Confirm observed recovery time stays within the documented RTO and recovery point stays within the documented RPO.

## Upgrade Validation

1. Stage the target Paid release in a non-production environment that matches the production topology.
2. Run migrations, smoke tests, and critical account workflows before approving production rollout.
3. Document rollback prerequisites and rollback timing before the production change window.
4. Record the last validated upgrade date in the compliance dashboard after the rehearsal completes.

## Secret Rotation

1. Rotate customer-managed keys and provider credentials on the tenant-defined interval or after personnel/incident triggers.
2. Update the compliance dashboard with the KMS provider, key reference, and most recent key rotation date.
3. Record the operator owner and most recent secret rotation workflow completion date.
4. Export a compliance evidence pack after each rotation cycle for audit review.
