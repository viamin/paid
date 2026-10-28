# frozen_string_literal: true

class CreateOpenrouterZdrCatalog < ActiveRecord::Migration[8.1]
  def change
    create_table :openrouter_zdr_models, comment: "Last-known OpenRouter endpoint-advertised ZDR eligibility by model." do |t|
      t.string :model_id, null: false, comment: "Concrete OpenRouter model ID advertised by one or more ZDR endpoints."
      t.jsonb :metadata, null: false, default: {}, comment: "Matched model metadata and the advertised eligible endpoint records."
      t.boolean :active, null: false, default: true, comment: "Whether the model appeared in the most recent successful ZDR endpoint refresh."
      t.datetime :last_verified_at, comment: "When a successful OpenRouter refresh last advertised this model."

      t.timestamps
    end
    add_index :openrouter_zdr_models, :model_id, unique: true
    add_index :openrouter_zdr_models, :active

    create_table :openrouter_zdr_catalog_states, comment: "Singleton freshness and availability state for the OpenRouter ZDR endpoint catalog." do |t|
      t.datetime :last_successful_refresh_at, comment: "When the endpoint catalog was last successfully replaced, including an empty result."
      t.datetime :last_attempted_refresh_at, comment: "When a refresh was most recently attempted."
      t.datetime :unavailable_at, comment: "When the latest refresh became unavailable; null after a successful refresh."
      t.string :last_error_class, comment: "Class of the most recent unavailable refresh error."

      t.timestamps
    end
  end
end
