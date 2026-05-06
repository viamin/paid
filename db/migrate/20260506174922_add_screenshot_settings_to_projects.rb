# frozen_string_literal: true

class AddScreenshotSettingsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :screenshot_settings, :jsonb, default: {}, null: false,
      comment: "Project-level defaults and overrides for repository screenshot capture config"
  end
end
