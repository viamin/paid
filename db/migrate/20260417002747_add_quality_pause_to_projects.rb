# frozen_string_literal: true

class AddQualityPauseToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :quality_paused_at, :datetime
    add_column :projects, :quality_pause_metadata, :jsonb, default: {}, null: false
    add_index :projects, :quality_paused_at, where: "quality_paused_at IS NOT NULL"
  end
end
