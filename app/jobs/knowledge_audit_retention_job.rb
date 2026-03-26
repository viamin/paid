# frozen_string_literal: true

class KnowledgeAuditRetentionJob < ApplicationJob
  RETENTION_PERIOD = 90.days

  queue_as :maintenance

  def perform
    deleted = KnowledgeAuditEvent.where("created_at < ?", RETENTION_PERIOD.ago).delete_all

    Rails.logger.info(
      message: "knowledge.audit.retention",
      deleted_count: deleted
    )
  end
end
