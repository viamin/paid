# frozen_string_literal: true

class SetLayeredVerificationObligationChangeIntentDeleteRule < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_key :layered_verification_obligations, :change_intents
    add_foreign_key :layered_verification_obligations, :change_intents, on_delete: :nullify, validate: false
  end

  def down
    remove_foreign_key :layered_verification_obligations, :change_intents
    add_foreign_key :layered_verification_obligations, :change_intents
  end
end
