# frozen_string_literal: true

class CreateAppleVerificationWorkflowsAndAttempts < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :apple_verification_settings, :jsonb, default: {}, null: false, comment: "Apple verification mode and inferred repository profiles (RDR-068)."
    create_table :apple_verification_workflow_revisions, comment: "Committed Apple verification workflow revisions and digest-bound approvals." do |t|
      t.references :project, null: false, foreign_key: true
      t.references :approved_by, foreign_key: { to_table: :users }
      t.string :profile_name, null: false
      t.string :state, null: false, default: "draft"
      t.string :source_digest, null: false
      t.jsonb :referenced_files, null: false, default: []
      t.jsonb :worker_constraints, null: false, default: {}
      t.jsonb :checks, null: false, default: {}
      t.string :lifecycle_gate
      t.datetime :approved_at
      t.timestamps
    end
    add_index :apple_verification_workflow_revisions, [ :project_id, :profile_name, :created_at ], name: "index_apple_workflows_on_project_profile_created"
    create_table :apple_verification_attempts, comment: "Apple verification queue, execution, and outcome state." do |t|
      t.references :project, null: false, foreign_key: true
      t.references :workflow_revision, null: false, foreign_key: { to_table: :apple_verification_workflow_revisions }
      t.references :retry_of, foreign_key: { to_table: :apple_verification_attempts }
      t.references :waived_by, foreign_key: { to_table: :users }
      t.string :state, null: false, default: "queued"
      t.integer :queue_position
      t.string :failure_class
      t.jsonb :result, null: false, default: {}
      t.jsonb :provenance, null: false, default: {}
      t.text :waiver_reason
      t.datetime :cancelled_at
      t.datetime :retained_vm_destroyed_at
      t.timestamps
    end
    add_index :apple_verification_attempts, [ :project_id, :state, :created_at ], name: "index_apple_attempts_on_project_state_created"
    create_table :apple_verification_artifacts, comment: "Private Apple verification artifacts with protected storage references." do |t|
      t.references :attempt, null: false, foreign_key: { to_table: :apple_verification_attempts }
      t.string :kind, null: false
      t.string :storage_key, null: false
      t.string :content_type
      t.jsonb :metadata, null: false, default: {}
      t.datetime :expires_at
      t.timestamps
    end
    add_index :apple_verification_artifacts, [ :attempt_id, :kind ]
  end
end
