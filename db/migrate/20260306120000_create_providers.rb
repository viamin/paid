# frozen_string_literal: true

class CreateProviders < ActiveRecord::Migration[8.0]
  class MigrationUser < ApplicationRecord
    self.table_name = "users"
  end

  class MigrationUserSetting < ApplicationRecord
    self.table_name = "user_settings"
  end

  class MigrationProvider < ApplicationRecord
    self.table_name = "providers"
  end

  SUPPORTED_KEYS = %w[claude cursor aider].freeze

  def up
    create_table :providers do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :provider_key, null: false, limit: 50
      t.boolean :enabled_for_agent_runs, null: false, default: true
      t.boolean :enabled_for_fallback, null: false, default: true
      t.jsonb :config, null: false, default: {}

      t.timestamps
    end

    add_index :providers, [ :user_id, :provider_key ], unique: true

    backfill_default_providers
  end

  def down
    drop_table :providers
  end

  private

  def backfill_default_providers
    MigrationUser.find_each do |user|
      setting = MigrationUserSetting.find_by(user_id: user.id)

      provider_keys = [ "claude" ]
      provider_keys << setting.default_agent_provider if setting&.default_agent_provider.present?
      provider_keys.concat(Array(setting&.fallback_providers))

      provider_keys.uniq!
      provider_keys.select! { |key| SUPPORTED_KEYS.include?(key) }

      provider_keys.each do |provider_key|
        MigrationProvider.find_or_create_by!(user_id: user.id, provider_key: provider_key)
      end
    end
  end
end
