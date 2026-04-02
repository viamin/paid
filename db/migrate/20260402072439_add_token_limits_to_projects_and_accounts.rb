# frozen_string_literal: true

class AddTokenLimitsToProjectsAndAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :default_max_tokens_per_run, :integer, default: 10_000_000, null: false

    add_column :projects, :max_tokens_per_run, :integer
    add_column :projects, :token_limit_warning_threshold, :integer, default: 80, null: false

    add_column :agent_runs, :token_limit_status, :string, limit: 50
  end
end
