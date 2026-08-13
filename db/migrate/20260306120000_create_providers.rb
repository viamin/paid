# frozen_string_literal: true

class CreateProviders < ActiveRecord::Migration[8.1]
  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"
  end

  class MigrationUserSetting < ActiveRecord::Base
    self.table_name = "user_settings"
  end

  class MigrationProvider < ActiveRecord::Base
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

    MigrationProvider.reset_column_information

    backfill_default_providers
  end

  def down
    drop_table :providers
  end

  private

  def backfill_default_providers
    MigrationUser.find_in_batches(batch_size: 1000) do |users|
      user_ids = users.map(&:id)
      settings_by_user_id = MigrationUserSetting.where(user_id: user_ids).index_by(&:user_id)

      existing_pairs = {}
      MigrationProvider.where(user_id: user_ids).pluck(:user_id, :provider_key).each do |user_id, provider_key|
        existing_pairs[[ user_id, provider_key ]] = true
      end

      now = Time.current
      records_to_insert = []

      users.each do |user|
        setting = settings_by_user_id[user.id]

        provider_keys = [ "claude" ]
        provider_keys << setting.default_agent_provider if setting&.default_agent_provider.present?
        provider_keys.concat(Array(setting&.fallback_providers))
        provider_keys.uniq!
        provider_keys.select! { |key| SUPPORTED_KEYS.include?(key) }

        provider_keys.each do |provider_key|
          key = [ user.id, provider_key ]
          next if existing_pairs[key]

          existing_pairs[key] = true
          records_to_insert << {
            user_id: user.id,
            provider_key: provider_key,
            enabled_for_agent_runs: true,
            enabled_for_fallback: true,
            config: {},
            created_at: now,
            updated_at: now
          }
        end
      end

      MigrationProvider.insert_all(records_to_insert, unique_by: %i[user_id provider_key]) if records_to_insert.any?
    end
  end
end
