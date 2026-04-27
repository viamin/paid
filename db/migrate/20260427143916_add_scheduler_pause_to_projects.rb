# frozen_string_literal: true

class AddSchedulerPauseToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :scheduler_paused_at, :datetime
    add_column :projects, :scheduler_pause_reason, :string
    add_index :projects, :scheduler_paused_at, where: "scheduler_paused_at IS NOT NULL"
  end
end
