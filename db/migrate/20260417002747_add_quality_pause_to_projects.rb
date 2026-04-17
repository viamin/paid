# frozen_string_literal: true

class AddQualityPauseToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :quality_paused_at, :datetime
    add_column :projects, :quality_pause_metadata, :jsonb, default: {}, null: false
  end
end
