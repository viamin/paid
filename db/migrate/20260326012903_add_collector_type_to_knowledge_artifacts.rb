# frozen_string_literal: true

class AddCollectorTypeToKnowledgeArtifacts < ActiveRecord::Migration[8.1]
  def up
    add_column :knowledge_artifacts, :collector_type, :string, limit: 100, null: true

    # Backfill collector_type from associated collector_run, then enforce NOT NULL
    # so the DB constraint matches the model-level presence validation and prevents
    # NULL values from bypassing the partial unique index.
    execute <<~SQL
      UPDATE knowledge_artifacts
      SET collector_type = collector_runs.collector_type
      FROM collector_runs
      WHERE knowledge_artifacts.collector_run_id = collector_runs.id
        AND knowledge_artifacts.collector_type IS NULL
    SQL

    change_column_null :knowledge_artifacts, :collector_type, false

    # Update the partial unique index to include collector_type so that
    # different collectors can produce artifacts with the same key without
    # conflicting at the DB layer
    remove_index :knowledge_artifacts,
      name: "idx_knowledge_artifacts_active_unique",
      if_exists: true

    remove_index :knowledge_artifacts,
      name: "idx_knowledge_artifacts_on_project_type_scope_identifier_status",
      if_exists: true

    add_index :knowledge_artifacts,
      [ :project_id, :artifact_type, :scope_path, :identifier, :collector_type, :status ],
      name: "idx_knowledge_artifacts_on_project_type_scope_id_ctype_status"

    add_index :knowledge_artifacts,
      [ :project_id, :artifact_type, :scope_path, :identifier, :collector_type ],
      unique: true,
      where: "status = 'active'",
      name: "idx_knowledge_artifacts_active_unique"
  end

  def down
    remove_index :knowledge_artifacts,
      name: "idx_knowledge_artifacts_active_unique",
      if_exists: true

    remove_index :knowledge_artifacts,
      name: "idx_knowledge_artifacts_on_project_type_scope_id_ctype_status",
      if_exists: true

    add_index :knowledge_artifacts,
      [ :project_id, :artifact_type, :scope_path, :identifier, :status ],
      name: "idx_knowledge_artifacts_on_project_type_scope_identifier_status"

    add_index :knowledge_artifacts,
      [ :project_id, :artifact_type, :scope_path, :identifier ],
      unique: true,
      where: "status = 'active'",
      name: "idx_knowledge_artifacts_active_unique"

    remove_column :knowledge_artifacts, :collector_type
  end
end
