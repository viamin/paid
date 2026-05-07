# frozen_string_literal: true

class EnsureProjectScreenshotSettingsColumn < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:projects, :screenshot_settings)

    add_column :projects, :screenshot_settings, :jsonb, default: {}, null: false,
      comment: "Project-level defaults and overrides for repository screenshot capture config"
  end

  def down
    remove_column :projects, :screenshot_settings, :jsonb if column_exists?(:projects, :screenshot_settings)
  end
end
