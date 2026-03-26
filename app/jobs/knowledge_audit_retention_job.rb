# frozen_string_literal: true

class KnowledgeAuditRetentionJob < ApplicationJob
  RETENTION_PERIOD = 90.days

  queue_as :maintenance

  def perform
    scope = KnowledgeAuditEvent.where("created_at < ?", RETENTION_PERIOD.ago)
    deleted_total = 0

    scope.in_batches(of: 1_000) do |relation|
      batch_deleted = relation.delete_all
      deleted_total += batch_deleted

      Rails.logger.info(
        message: "knowledge.audit.retention.batch",
        batch_deleted_count: batch_deleted,
        deleted_total: deleted_total
      )
    end

    Rails.logger.info(
      message: "knowledge.audit.retention",
      deleted_count: deleted_total
    )
  end
end
