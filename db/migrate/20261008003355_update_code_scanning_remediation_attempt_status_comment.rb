# frozen_string_literal: true

class UpdateCodeScanningRemediationAttemptStatusComment < ActiveRecord::Migration[8.1]
  def change
    return unless table_exists?(:code_scanning_remediation_attempts) &&
      column_exists?(:code_scanning_remediation_attempts, :status)

    change_column_comment :code_scanning_remediation_attempts, :status,
      "awaiting_verification, verified_fixed, verification_failed, verification_blocked, or upstream_resolved."
  end
end
