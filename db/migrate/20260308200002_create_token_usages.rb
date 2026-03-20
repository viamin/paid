# frozen_string_literal: true

class CreateTokenUsages < ActiveRecord::Migration[8.1]
  def change
    create_table :token_usages do |t|
      # index: false because the composite index on [agent_run_id, request_type] below
      # covers agent_run_id lookups via leftmost prefix in Postgres
      t.references :agent_run, null: false, index: false, foreign_key: { on_delete: :cascade }
      # Named llm_model (not model_name) to avoid ActiveRecord's reserved model_name method
      t.string :llm_model, limit: 100
      t.string :request_type, limit: 50, null: false
      t.integer :input_tokens, default: 0, null: false
      t.integer :output_tokens, default: 0, null: false
      t.integer :cost_cents, default: 0, null: false
      t.jsonb :metadata, default: {}, null: false
      t.timestamps
    end

    add_index :token_usages, :llm_model
    add_index :token_usages, :request_type
    add_index :token_usages, :created_at
    add_index :token_usages, [ :agent_run_id, :request_type ]
  end
end
