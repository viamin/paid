# frozen_string_literal: true

class AddQualityGateSettingsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :quality_gate_settings, :jsonb, default: {}, null: false
  end
end
