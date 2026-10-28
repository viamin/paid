# frozen_string_literal: true

class AddOpenrouterZdrEligibilityToLlmModels < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :llm_models, :openrouter_zdr_eligible, :boolean, default: false, null: false
    add_column :llm_models, :openrouter_zdr_checked_at, :datetime
    add_index :llm_models, [ :openrouter_zdr_eligible, :active ], algorithm: :concurrently
  end
end
