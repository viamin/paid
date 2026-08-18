# frozen_string_literal: true

class AddPrAutoContinueTokenLimitOverrideToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :pr_auto_continue_token_limit_overridden_at, :datetime,
      comment: "When set, owner dismissed a PR token-cap escalation and allowed this PR to exceed the automatic PR token cap.",
      if_not_exists: true
  end
end
