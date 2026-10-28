# frozen_string_literal: true

class AddOpenrouterZdrEligibilityToLlmModels < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :llm_models, :openrouter_zdr_eligible, :boolean, default: false, null: false,
      comment: "Whether OpenRouter currently advertises at least one ZDR endpoint for this model."
    add_column :llm_models, :openrouter_zdr_endpoint_metadata, :jsonb, default: {}, null: false,
      comment: "Latest advertised OpenRouter ZDR endpoint records grouped by model."
    add_index :llm_models, :openrouter_zdr_eligible, algorithm: :concurrently
  end
end
