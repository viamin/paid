# frozen_string_literal: true

class ValidateChangeIntentsSupersededByForeignKey < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :change_intents, :change_intents
  end
end
