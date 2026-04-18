# frozen_string_literal: true

class AddOnboardingToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :plan, :string, default: "trial", null: false
    add_column :accounts, :onboarding_completed_at, :datetime
    add_column :accounts, :trial_ends_at, :datetime
  end
end
