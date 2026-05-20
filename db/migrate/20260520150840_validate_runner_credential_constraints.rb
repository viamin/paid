# frozen_string_literal: true

class ValidateRunnerCredentialConstraints < ActiveRecord::Migration[8.1]
  def change
    validate_check_constraint :runners, name: "runners_api_key_requires_key"
    validate_check_constraint :runners, name: "runners_subscription_invariants"
  end
end
