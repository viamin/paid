# frozen_string_literal: true

class ClarifyBoundedPrTokenOverrideTimestamp < ActiveRecord::Migration[8.1]
  def change
    change_column_comment :issues, :pr_auto_continue_token_limit_overridden_at,
      "When the owner last dismissed a PR token-cap escalation; timestamp-only legacy records grant no allowance."
  end
end
