# frozen_string_literal: true

class CreateKnowledgeAuditEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :knowledge_audit_events do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.string :event_type, null: false, limit: 100
      t.string :actor_type, limit: 50
      t.string :actor_id, limit: 100
      t.string :target_type, limit: 100
      t.string :target_id, limit: 100
      t.jsonb :details, default: {}
      t.datetime :created_at, null: false
    end

    add_index :knowledge_audit_events,
              [ :project_id, :created_at, :id ],
              order: { created_at: :desc, id: :desc }
    add_index :knowledge_audit_events, :event_type
    add_index :knowledge_audit_events, [ :target_type, :target_id ]
  end
end
