# frozen_string_literal: true

class RelaxProviderApiKeyConstraintForDiscardedProviders < ActiveRecord::Migration[8.1]
  def change
    remove_check_constraint :providers, name: "providers_api_key_requires_key"
    add_check_constraint :providers,
      "(auth_type != 'api_key') OR provider_api_key_id IS NOT NULL OR discarded_at IS NOT NULL",
      name: "providers_api_key_requires_key"
  end
end
