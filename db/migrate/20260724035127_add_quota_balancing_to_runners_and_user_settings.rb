# frozen_string_literal: true

class AddQuotaBalancingToRunnersAndUserSettings < ActiveRecord::Migration[8.1]
  def up
    add_runner_budget_column
    add_user_auto_weight_column
  end

  def down
    remove_column :runners, :monthly_token_budget if column_exists?(:runners, :monthly_token_budget)
    remove_column :user_settings, :auto_weight_enabled if column_exists?(:user_settings, :auto_weight_enabled)
  end

  private

  def add_runner_budget_column
    return if column_exists?(:runners, :monthly_token_budget)

    add_column :runners, :monthly_token_budget, :integer,
      comment: "Optional per-runner monthly token budget used to auto-balance API-key runner weights. Null means unlimited or unknown."
  end

  def add_user_auto_weight_column
    return if column_exists?(:user_settings, :auto_weight_enabled)

    add_column :user_settings, :auto_weight_enabled, :boolean, default: false, null: false,
      comment: "Whether automated runner weights are recalculated from observed remaining quota instead of edited manually."
  end
end
