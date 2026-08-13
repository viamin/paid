# frozen_string_literal: true

class AddGitUnshallowTimeoutSecondsToUserSettings < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:user_settings, :git_unshallow_timeout_seconds)

    add_column :user_settings, :git_unshallow_timeout_seconds, :integer, default: 1800, null: false
  end

  def down
    return unless column_exists?(:user_settings, :git_unshallow_timeout_seconds)

    remove_column :user_settings, :git_unshallow_timeout_seconds
  end
end
