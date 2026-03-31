# frozen_string_literal: true

class ReplaceCompatibleProvidersWithApiServiceType < ActiveRecord::Migration[8.1]
  def up
    add_column :provider_api_keys, :api_service_type, :string, limit: 50

    # Use the ? operator for JSONB array membership checks.
    execute <<~SQL.squish
      UPDATE provider_api_keys
      SET api_service_type = CASE
        WHEN compatible_providers ? 'openrouter' THEN 'openrouter'
        WHEN compatible_providers ? 'openai' THEN 'openai'
        WHEN compatible_providers ? 'opencode' THEN 'openrouter'
        WHEN compatible_providers ? 'codex' THEN 'openai'
        WHEN compatible_providers ? 'gemini' THEN 'google'
        WHEN compatible_providers ? 'claude' THEN 'anthropic'
        WHEN compatible_providers ? 'cursor' THEN 'anthropic'
        WHEN compatible_providers ? 'copilot' THEN 'anthropic'
        WHEN compatible_providers ? 'aider' THEN 'anthropic'
        WHEN compatible_providers ? 'kilocode' THEN 'anthropic'
        ELSE 'anthropic'
      END
      WHERE api_service_type IS NULL
    SQL

    change_column_null :provider_api_keys, :api_service_type, false
    remove_column :provider_api_keys, :compatible_providers
  end

  def down
    add_column :provider_api_keys, :compatible_providers, :jsonb, default: [], null: false

    execute <<~SQL.squish
      UPDATE provider_api_keys
      SET compatible_providers = CASE api_service_type
        WHEN 'anthropic' THEN '["claude"]'::jsonb
        WHEN 'openai' THEN '["openai"]'::jsonb
        WHEN 'openrouter' THEN '["openrouter"]'::jsonb
        WHEN 'google' THEN '["gemini"]'::jsonb
        ELSE '["claude"]'::jsonb
      END
    SQL

    remove_column :provider_api_keys, :api_service_type
  end
end
