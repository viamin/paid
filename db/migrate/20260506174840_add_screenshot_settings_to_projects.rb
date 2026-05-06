# frozen_string_literal: true

# Per-project screenshot capture behavior. Stored as JSONB so projects can
# opt into automated capture and tune runtime requirements without further
# schema changes.
class AddScreenshotSettingsToProjects < ActiveRecord::Migration[8.1]
  DEFAULT_SCREENSHOT_SETTINGS = {
    enabled: false,
    driver: "playwright",
    capture_on_pr: true,
    config_path: ".paid/screenshots.yml",
    service_dependencies: [],
    setup_commands: [],
    auth_strategy: "none"
  }.freeze

  def up
    return if column_exists?(:projects, :screenshot_settings)

    add_column :projects, :screenshot_settings, :jsonb,
      default: DEFAULT_SCREENSHOT_SETTINGS,
      null: false,
      comment: "Per-project screenshot capture settings for automated and manual runs"
  end

  def down
    remove_column :projects, :screenshot_settings, :jsonb if column_exists?(:projects, :screenshot_settings)
  end
end
