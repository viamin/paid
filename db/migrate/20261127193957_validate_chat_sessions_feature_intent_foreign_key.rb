# frozen_string_literal: true

# @spec POSTGRESQL-PERSISTENCE-020
class ValidateChatSessionsFeatureIntentForeignKey < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :chat_sessions, :feature_intents, column: :feature_intent_id
  end
end
