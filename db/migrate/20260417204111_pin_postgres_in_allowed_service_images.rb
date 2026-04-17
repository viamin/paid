# frozen_string_literal: true

class PinPostgresInAllowedServiceImages < ActiveRecord::Migration[8.1]
  OLD_DEFAULT = [ "postgres:16", "redis:7-alpine", "selenium/standalone-chromium:latest" ].freeze
  NEW_DEFAULT = [ "postgres:16.13", "redis:7-alpine", "selenium/standalone-chromium:latest" ].freeze

  def up
    change_column_default :user_settings, :allowed_service_images, from: OLD_DEFAULT, to: NEW_DEFAULT

    execute(<<~SQL.squish)
      UPDATE user_settings
      SET allowed_service_images = (
        SELECT jsonb_agg(
          CASE WHEN elem = '"postgres:16"'::jsonb THEN '"postgres:16.13"'::jsonb ELSE elem END
        )
        FROM jsonb_array_elements(allowed_service_images) AS elem
      )
      WHERE allowed_service_images @> '["postgres:16"]'::jsonb
    SQL
  end

  def down
    change_column_default :user_settings, :allowed_service_images, from: NEW_DEFAULT, to: OLD_DEFAULT

    execute(<<~SQL.squish)
      UPDATE user_settings
      SET allowed_service_images = (
        SELECT jsonb_agg(
          CASE WHEN elem = '"postgres:16.13"'::jsonb THEN '"postgres:16"'::jsonb ELSE elem END
        )
        FROM jsonb_array_elements(allowed_service_images) AS elem
      )
      WHERE allowed_service_images @> '["postgres:16.13"]'::jsonb
    SQL
  end
end
