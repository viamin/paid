# frozen_string_literal: true

class ValidateAccountActivityEventsActorForeignKey < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :account_activity_events, :users, column: :actor_id
  end
end
