# frozen_string_literal: true

class CreateOpenRouterZdrCatalogs < ActiveRecord::Migration[8.1]
  def change
    create_table :open_router_zdr_catalogs, comment: "Freshness state for the OpenRouter advertised ZDR endpoint catalog." do |t|
      t.datetime :last_successful_at, comment: "When OpenRouter last returned a valid ZDR endpoint catalog."
      t.datetime :last_attempted_at, comment: "When a ZDR endpoint catalog refresh was last attempted."
      t.boolean :available, default: false, null: false, comment: "Whether the most recent refresh was successful."
      t.string :last_error, comment: "Failure summary for the most recent unsuccessful refresh."
      t.timestamps
    end

    create_table :open_router_zdr_catalog_entries, comment: "Advertised OpenRouter ZDR endpoint eligibility mapped to catalog models." do |t|
      t.references :open_router_zdr_catalog, null: false, foreign_key: true
      t.references :llm_model, null: false, index: { unique: true }, foreign_key: true
      t.integer :endpoint_count, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
  end
end
