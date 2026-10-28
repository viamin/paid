# frozen_string_literal: true

class UpdateLlmModelCatalogSourceComment < ActiveRecord::Migration[8.1]
  def change
    change_column_comment :llm_models, :catalog_source,
      "How this model entered the catalog: seeded, openrouter_sync, openrouter_zdr_sync, or manual."
  end
end
