# frozen_string_literal: true

class AddOpenrouterZdrCatalogToLlmModels < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :llm_models, :zdr_eligible, :boolean, default: false, null: false,
      comment: "Whether OpenRouter currently advertises at least one ZDR-eligible endpoint for this model."
    add_column :llm_models, :zdr_checked_at, :datetime,
      comment: "When OpenRouter ZDR endpoint eligibility was last successfully evaluated for this model."
    add_index :llm_models, :zdr_eligible, algorithm: :concurrently

    create_table :openrouter_zdr_catalog_statuses do |t|
      t.string :source, null: false
      t.string :status, null: false, default: "unavailable"
      t.datetime :last_attempt_at
      t.datetime :last_success_at
      t.text :last_error
      t.timestamps
    end

    add_index :openrouter_zdr_catalog_statuses, :source, unique: true, algorithm: :concurrently
  end
end
