# frozen_string_literal: true

# RDR-061 — enforces retention on the append-only execution audit trail.
# Security/infrastructure audit events are kept longer than operational
# telemetry (see docs/DATA_MODEL.md "Data Retention") to support incident
# investigation and compliance review windows.
#
# @spec EXECUTION-AUDIT-003
class ExecutionAuditEventRetentionJob < ApplicationJob
  DEFAULT_RETENTION_PERIOD = 400.days

  queue_as :maintenance

  def perform(retention_period: DEFAULT_RETENTION_PERIOD)
    cutoff = retention_period.ago
    scope = ExecutionAuditEvent.where("created_at < ?", cutoff)
    deleted_total = 0

    scope.in_batches(of: 1_000) do |relation|
      batch_deleted = relation.delete_all
      deleted_total += batch_deleted

      Rails.logger.info(
        message: "execution_audit.retention.batch",
        batch_deleted_count: batch_deleted,
        deleted_total: deleted_total
      )
    end

    Rails.logger.info(
      message: "execution_audit.retention.complete",
      deleted_count: deleted_total,
      retention_days: retention_period.in_days.to_i
    )

    deleted_total
  end
end
