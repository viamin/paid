# frozen_string_literal: true

# @spec FEATURE-APPROVAL-009
class ValidateFeatureIntentsApprovedByForeignKey < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :feature_intents, :users
  end
end
