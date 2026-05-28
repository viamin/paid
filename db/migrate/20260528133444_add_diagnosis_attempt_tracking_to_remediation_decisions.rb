# frozen_string_literal: true

class AddDiagnosisAttemptTrackingToRemediationDecisions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  class MigrationRemediationDecision < ActiveRecord::Base
    self.table_name = "remediation_decisions"
  end

  def up
    add_column :remediation_decisions, :diagnosis_attempted_on, :date,
      comment: "UTC day when this fingerprint last consumed diagnosis budget."
    add_column :remediation_decisions, :diagnosis_attempt_count_on_day, :integer, default: 1, null: false,
      comment: "How many diagnosis attempts for this fingerprint consumed budget on diagnosis_attempted_on."
    add_column :remediation_decisions, :last_diagnosis_attempt_at, :datetime,
      comment: "Timestamp of the most recent diagnosis attempt recorded for this audit row."
    add_index :remediation_decisions, [ :account_id, :diagnosis_attempted_on ],
      name: "idx_remediation_decisions_budget_lookup", algorithm: :concurrently

    MigrationRemediationDecision.reset_column_information
    MigrationRemediationDecision.find_each do |decision|
      attempted_at = decision.created_at || Time.current
      decision.update_columns(
        diagnosis_attempted_on: attempted_at.to_date,
        diagnosis_attempt_count_on_day: 1,
        last_diagnosis_attempt_at: attempted_at
      )
    end
  end

  def down
    remove_index :remediation_decisions, name: "idx_remediation_decisions_budget_lookup", algorithm: :concurrently
    remove_column :remediation_decisions, :last_diagnosis_attempt_at
    remove_column :remediation_decisions, :diagnosis_attempt_count_on_day
    remove_column :remediation_decisions, :diagnosis_attempted_on
  end
end
