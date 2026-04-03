# frozen_string_literal: true

class AddMaxExecutionSecondsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :max_execution_seconds, :integer, default: 1800, null: false
  end
end
