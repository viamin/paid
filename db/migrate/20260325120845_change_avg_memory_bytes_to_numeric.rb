# frozen_string_literal: true

class ChangeAvgMemoryBytesToNumeric < ActiveRecord::Migration[8.1]
  def up
    change_column :agent_runs, :avg_memory_bytes, :numeric
  end

  def down
    change_column :agent_runs, :avg_memory_bytes, :bigint
  end
end
