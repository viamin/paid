# frozen_string_literal: true

class ValidateLayeredVerificationObligationChangeIntentDeleteRule < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :layered_verification_obligations, :change_intents
  end
end
