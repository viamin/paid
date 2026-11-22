# frozen_string_literal: true

class CreateConflictRepairScopeEvidences < ActiveRecord::Migration[8.1]
  def change
    create_table :conflict_repair_scope_evidences, comment: "Immutable, provider-head-bound scope decisions for existing conflict-repair artifacts." do |t|
      t.references :agent_run, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :issue, null: false, foreign_key: true
      t.references :requested_by, foreign_key: { to_table: :users }
      t.string :pre_run_sha, null: false
      t.string :integration_base_sha, null: false
      t.string :result_sha, null: false
      t.string :provider_head_sha, null: false
      t.string :status, null: false
      t.text :explanation, null: false
      t.jsonb :base_imported_paths, null: false, default: []
      t.jsonb :repair_authored_paths, null: false, default: []
      t.timestamps
    end

    add_index :conflict_repair_scope_evidences,
      %i[agent_run_id pre_run_sha integration_base_sha result_sha provider_head_sha],
      unique: true, name: "index_conflict_repair_scope_evidence_binding"
  end
end
