# frozen_string_literal: true

# Runs a dispatched layered-verification audit: executes the checks its plan
# selected, records every outcome, synthesizes coverage, and records the
# findings the audit produced.
#
# @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-024
class LayeredVerificationAuditExecuteJob < ApplicationJob
  queue_as :default

  def perform(audit_id)
    audit = LayeredVerificationAudit.find_by(id: audit_id)
    return unless audit
    return if audit.terminal?

    LayeredVerification::Audits::Execute.call(audit: audit)
  rescue StandardError => e
    Rails.logger.error(
      message: "layered_verification.audit_execution_failed",
      audit_id: audit_id,
      error_class: e.class.name,
      error: e.message
    )
    audit&.update!(
      status: "failed",
      waiting_reason: "the audit could not be completed",
      completed_at: Time.current
    ) unless audit&.terminal?
    audit&.agent_run&.fail!(error: "the audit could not be completed")
    raise
  end
end
