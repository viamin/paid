# frozen_string_literal: true

module AuditLogging
  extend ActiveSupport::Concern

  private

  def audit_event(action, subject: nil, metadata: {}, account: nil)
    Audit::RecordEvent.call(
      action: action,
      actor: current_user,
      subject: subject || resolve_audit_subject,
      metadata: metadata,
      account: account || resolve_audit_account
    )
  rescue StandardError => e
    Rails.logger.error(
      message: "audit.record_failed",
      action: action,
      error_class: e.class.name,
      error_message: e.message
    )
    nil
  end

  def resolve_audit_subject
    nil
  end

  def resolve_audit_account
    current_account
  end
end
