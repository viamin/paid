# frozen_string_literal: true

class AddBoundedPrTokenLimitOverrides < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :pr_auto_continue_token_limit_override_usage, :bigint,
      comment: "Recorded automatic PR token usage when the owner granted the current bounded override.",
      if_not_exists: true
    add_column :issues, :pr_auto_continue_token_limit_override_allowance, :bigint,
      comment: "Additional automatic PR token allowance granted by the owner's latest token-cap dismissal.",
      if_not_exists: true
  end
end
