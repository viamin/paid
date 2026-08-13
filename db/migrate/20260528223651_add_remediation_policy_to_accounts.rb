# frozen_string_literal: true

class AddRemediationPolicyToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :remediation_policy, :jsonb, default: {}, null: false,
      comment: "Per-action self-heal remediation modes and thresholds for this account."
  end
end
