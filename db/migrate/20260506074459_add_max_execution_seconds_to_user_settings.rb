# frozen_string_literal: true

class AddMaxExecutionSecondsToUserSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :user_settings, :max_execution_seconds, :integer,
      comment: "User-level override for project max_execution_seconds; nil defers to project setting"
  end
end
