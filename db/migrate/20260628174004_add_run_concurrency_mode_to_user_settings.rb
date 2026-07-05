# frozen_string_literal: true

class AddRunConcurrencyModeToUserSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :user_settings, :run_concurrency_mode, :string,
      default: "manual",
      null: false,
      comment: "Whether agent run admission uses the fixed max_concurrent_runs limit or Docker-capacity auto admission."
    change_column_null :user_settings, :max_concurrent_runs, true
  end
end
