# frozen_string_literal: true

class SetAllowedServiceImagesNotNull < ActiveRecord::Migration[8.1]
  DEFAULT_IMAGES = [ "postgres:16", "redis:7-alpine", "selenium/standalone-chromium:latest" ].freeze

  def up
    execute <<~SQL
      UPDATE user_settings
      SET allowed_service_images = '#{DEFAULT_IMAGES.to_json}'::jsonb
      WHERE allowed_service_images IS NULL
    SQL

    change_column_default :user_settings, :allowed_service_images, from: nil, to: DEFAULT_IMAGES
    change_column_null :user_settings, :allowed_service_images, false
  end

  def down
    change_column_null :user_settings, :allowed_service_images, true
    change_column_default :user_settings, :allowed_service_images, from: DEFAULT_IMAGES, to: nil
  end
end
