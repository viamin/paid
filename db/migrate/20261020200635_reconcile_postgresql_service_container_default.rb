# frozen_string_literal: true

class ReconcilePostgresqlServiceContainerDefault < ActiveRecord::Migration[8.1] # @spec TOOLCHAIN-PIN-025
  OLD_DEFAULT = [ "postgres:16.13", "redis:7-alpine", "selenium/standalone-chromium:latest" ].freeze
  NEW_DEFAULT = [ "postgres:16.15", "redis:7-alpine", "selenium/standalone-chromium:latest" ].freeze

  def up
    change_column_default :user_settings, :allowed_service_images, from: OLD_DEFAULT, to: NEW_DEFAULT
    update_exact_default(from: OLD_DEFAULT, to: NEW_DEFAULT)
  end

  def down
    change_column_default :user_settings, :allowed_service_images, from: NEW_DEFAULT, to: OLD_DEFAULT
    update_exact_default(from: NEW_DEFAULT, to: OLD_DEFAULT)
  end

  private

  def update_exact_default(from:, to:)
    safety_assured do
      execute <<~SQL.squish
        UPDATE user_settings
        SET allowed_service_images = #{connection.quote(to.to_json)}::jsonb
        WHERE allowed_service_images = #{connection.quote(from.to_json)}::jsonb
      SQL
    end
  end
end
