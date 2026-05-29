# frozen_string_literal: true

class AddInteroperabilitySettingsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :interop_settings, :jsonb,
      default: {},
      null: false,
      comment: "Project-level coexistence settings for gradual adoption, imports, connectors, and external execution sources."
  end
end
