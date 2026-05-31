# frozen_string_literal: true

class ValidateFreeVariantOfForeignKeyOnLlmModels < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :llm_models, :llm_models, column: :free_variant_of_id
  end
end
