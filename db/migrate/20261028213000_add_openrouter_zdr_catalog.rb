# frozen_string_literal: true

class AddOpenrouterZdrCatalog < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :llm_models, :openrouter_zdr_eligible, :boolean, default: false, null: false,
      comment: "Whether OpenRouter currently advertises at least one ZDR endpoint for this model."
    add_index :llm_models, :openrouter_zdr_eligible, algorithm: :concurrently

    create_table :openrouter_zdr_refreshes do |t|
      t.string :source, null: false
      t.string :status, null: false, default: "unavailable"
      t.datetime :last_attempt_at
      t.datetime :last_success_at
      t.string :error_class
      t.text :error_message

      t.timestamps
    end

    add_index :openrouter_zdr_refreshes, :source, unique: true, algorithm: :concurrently
    add_check_constraint :openrouter_zdr_refreshes, "status IN ('available', 'unavailable')",
      name: "openrouter_zdr_refreshes_status_check"
  end
end
