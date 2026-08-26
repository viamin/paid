# frozen_string_literal: true

class AddFollowupAttemptsToPageLoadRegressionFindings < ActiveRecord::Migration[8.1]
  def change
    add_column :page_load_regression_findings, :followup_attempts, :integer, null: false, default: 0,
      comment: "Follow-up runs queued for this finding. Caps automated retries so a regression the agent cannot fix stops consuming runner budget."

    # page_load_regression_findings is created in this same release, so the
    # validating scan has no rows to walk and cannot block writes.
    safety_assured do
      add_check_constraint :page_load_regression_findings,
        "followup_attempts >= 0",
        name: "chk_page_load_findings_attempts_non_negative"
    end
  end
end
