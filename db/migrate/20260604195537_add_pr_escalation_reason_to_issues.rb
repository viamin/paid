# frozen_string_literal: true

class AddPrEscalationReasonToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :pr_escalation_reason, :string,
      comment: "Machine-readable cause for the current PR escalation so only operational outages can auto-dismiss."
  end
end
