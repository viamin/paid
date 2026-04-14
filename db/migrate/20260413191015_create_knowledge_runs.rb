# frozen_string_literal: true

class CreateKnowledgeRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :knowledge_runs do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.string :operation_type, limit: 50, null: false
      t.string :status, limit: 50, null: false, default: "pending"
      t.string :final_provider, limit: 50
      t.jsonb :provider_attempts, null: false, default: []
      t.integer :total_tokens, null: false, default: 0
      t.string :proxy_token, limit: 64
      t.string :token_limit_status, limit: 50
      t.integer :max_tokens

      t.timestamps
    end

    add_index :knowledge_runs, :proxy_token, unique: true
    add_index :knowledge_runs, [ :project_id, :status ]
  end
end
