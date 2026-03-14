# frozen_string_literal: true

class CreateTokenUsages < ActiveRecord::Migration[8.1]
  def change
    create_table :token_usages do |t|
      t.bigint :agent_run_id, null: false
      t.string :llm_model, limit: 100
      t.string :request_type, limit: 50, null: false
      t.integer :input_tokens, default: 0, null: false
      t.integer :output_tokens, default: 0, null: false
      t.integer :cost_cents, default: 0, null: false
      t.jsonb :metadata, default: {}, null: false
      t.timestamps
    end

    add_index :token_usages, :agent_run_id
    add_index :token_usages, :llm_model
    add_index :token_usages, :request_type
    add_index :token_usages, :created_at
    add_index :token_usages, [ :agent_run_id, :request_type ]
    add_foreign_key :token_usages, :agent_runs, on_delete: :cascade
  end
end
