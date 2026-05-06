# frozen_string_literal: true

class AddScreenshotSettingsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :screenshot_settings, :jsonb, default: {}, null: false,
      comment: "Per-project screenshot capture configuration and detection metadata."
    add_column :projects, :screenshot_status, :jsonb, default: {}, null: false,
      comment: "Latest screenshot capture status shown in project settings."
  end
end
