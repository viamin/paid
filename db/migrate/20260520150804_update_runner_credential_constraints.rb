# frozen_string_literal: true

class UpdateRunnerCredentialConstraints < ActiveRecord::Migration[8.1]
  def change
    remove_check_constraint :runners, name: "runners_api_key_requires_key"
    remove_check_constraint :runners, name: "runners_subscription_invariants"

    add_check_constraint :runners,
      "auth_type::text <> 'api_key'::text OR provider_api_key_id IS NOT NULL OR integration_credential_id IS NOT NULL OR discarded_at IS NOT NULL",
      name: "runners_api_key_requires_key",
      validate: false
    add_check_constraint :runners,
      "auth_type::text <> 'subscription'::text OR (provider_api_key_id IS NULL AND integration_credential_id IS NULL AND fallback_role::text = 'standard'::text)",
      name: "runners_subscription_invariants",
      validate: false
  end
end
