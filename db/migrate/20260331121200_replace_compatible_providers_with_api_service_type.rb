# frozen_string_literal: true

class ReplaceCompatibleProvidersWithApiServiceType < ActiveRecord::Migration[8.1]
  def up
    add_column :provider_api_keys, :api_service_type, :string, limit: 50

    # Collapse the multi-valued compatible_providers array into a single
    # api_service_type. When a key lists providers that map to different
    # upstream services (e.g. both openai and openrouter entries), the CASE
    # uses first-match precedence: third-party aggregators (openrouter) win
    # over direct-provider entries (openai), then direct providers, then
    # anthropic as the default. In practice, keys were created via a UI that
    # grouped providers by service type, so mixed-service arrays should not
    # exist; this precedence is a defensive fallback when they do.
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
        WHEN compatible_providers ? 'aider' THEN 'anthropic'
        WHEN compatible_providers ? 'kilocode' THEN 'anthropic'
        /* copilot is intentionally excluded from explicit WHEN branches: it uses
           GitHub subscription auth, not a third-party API key (see
           ProviderSupport::PROVIDER_API_SERVICE_TYPE). Copilot-only API key
           records should not exist in practice. Any that do fall through to
           the ELSE 'anthropic' default below, which means they become
           selectable for Anthropic-backed providers. This is acceptable
           because such records are purely theoretical — the UI never allowed
           creating an API key with only copilot selected. */
        ELSE 'anthropic'
      END
      WHERE api_service_type IS NULL
    SQL

    change_column_null :provider_api_keys, :api_service_type, false
    add_index :provider_api_keys, %i[user_id api_service_type], name: "index_provider_api_keys_on_user_id_and_api_service_type"
    remove_column :provider_api_keys, :compatible_providers
  end

  def down
    remove_index :provider_api_keys, name: "index_provider_api_keys_on_user_id_and_api_service_type", if_exists: true
    add_column :provider_api_keys, :compatible_providers, :jsonb, default: [], null: false

    # Restore compatible_providers with all provider keys that map to each
    # service type, so rollback preserves pre-migration compatibility behavior.
    execute <<~SQL.squish
      UPDATE provider_api_keys
      SET compatible_providers = CASE api_service_type
        WHEN 'anthropic' THEN '["claude","cursor","aider","kilocode"]'::jsonb
        WHEN 'openai' THEN '["codex","openai"]'::jsonb
        WHEN 'openrouter' THEN '["opencode","openrouter"]'::jsonb
        WHEN 'google' THEN '["gemini"]'::jsonb
        ELSE '["claude","cursor","aider","kilocode"]'::jsonb
      END
    SQL

    remove_column :provider_api_keys, :api_service_type
  end
end
