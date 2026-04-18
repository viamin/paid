# frozen_string_literal: true

class AddCreatePrIdleTimeoutSecondsToUserSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :user_settings, :create_pr_idle_timeout_seconds, :integer, default: 300, null: false
  end
end
