# frozen_string_literal: true

class CreateDecisionRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :decision_records do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent_run, null: true, foreign_key: { on_delete: :nullify }
      t.references :issue, null: true, foreign_key: { on_delete: :nullify }
      t.string :title, limit: 500, null: false
      t.text :summary, null: false
      t.text :context
      t.text :decision, null: false
      t.text :consequences
      # Default to "draft" as a safety net — the Draft service explicitly sets "active"
      # when creating from a completed agent run, but records created through other
      # paths should start as drafts requiring explicit activation.
      t.string :status, limit: 50, null: false, default: "draft"
      t.bigint :superseded_by_id
      t.string :commit_sha_start, limit: 40
      t.string :commit_sha_end, limit: 40
      t.jsonb :tags, null: false, default: []
      t.timestamps
    end

    add_foreign_key :decision_records, :decision_records, column: :superseded_by_id, on_delete: :nullify
    add_index :decision_records, [ :project_id, :status ]
    add_index :decision_records, :tags, using: :gin
    add_index :decision_records, :superseded_by_id
  end
end
