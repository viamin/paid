# frozen_string_literal: true

class AddAutoContinuePausedToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :auto_continue_paused, :boolean, default: false, null: false
  end
end
