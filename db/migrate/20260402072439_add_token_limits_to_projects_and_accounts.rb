# frozen_string_literal: true

class AddTokenLimitsToProjectsAndAccounts < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:accounts, :default_max_tokens_per_run)
      add_column :accounts, :default_max_tokens_per_run, :integer, default: 10_000_000, null: false
    end

    add_column :projects, :max_tokens_per_run, :integer unless column_exists?(:projects, :max_tokens_per_run)
    unless column_exists?(:projects, :token_limit_warning_threshold)
      add_column :projects, :token_limit_warning_threshold, :integer, default: 80, null: false
    end

    add_column :agent_runs, :token_limit_status, :string, limit: 50 unless column_exists?(:agent_runs, :token_limit_status)
  end
end
