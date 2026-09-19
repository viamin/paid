# frozen_string_literal: true

class CreateAppleVerificationWorkers < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:projects, :apple_verification_mode)
      add_column :projects, :apple_verification_mode, :string, null: false, default: "off", comment: "Apple verification scheduling mode: off, on_demand, or automatic."
    end
    unless check_constraint_exists?(:projects, name: "chk_projects_apple_verification_mode")
      add_check_constraint :projects, "apple_verification_mode IN ('off', 'on_demand', 'automatic')", name: "chk_projects_apple_verification_mode", validate: false
    end

    create_table :apple_worker_profiles, comment: "Immutable provider-neutral Apple verification worker profiles." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }, comment: "Operator that registered the profile."
      t.string :name, null: false
      t.string :image_digest, null: false, comment: "Approved immutable guest image digest."
      t.jsonb :capabilities, null: false, default: {}, comment: "Provider-neutral capability inventory."
      t.jsonb :constraints, null: false, default: {}, comment: "Immutable platform, Xcode, runtime, and resource constraints."
      t.string :status, null: false, default: "active", comment: "active, deprecated, or revoked."
      t.timestamps
    end unless table_exists?(:apple_worker_profiles)
    add_index :apple_worker_profiles, [ :account_id, :name ], unique: true unless index_exists?(:apple_worker_profiles, [ :account_id, :name ], unique: true)
    unless check_constraint_exists?(:apple_worker_profiles, name: "chk_apple_worker_profiles_status")
      add_check_constraint :apple_worker_profiles, "status IN ('active', 'deprecated', 'revoked')", name: "chk_apple_worker_profiles_status"
    end

    create_table :apple_verification_workflow_revisions, comment: "Digest-bound Apple verification workflow revisions and approval state." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :apple_worker_profile, null: false, foreign_key: true
      t.references :approved_by, foreign_key: { to_table: :users }, comment: "Project administrator that approved this revision."
      t.integer :revision, null: false
      t.string :content_digest, null: false, comment: "SHA-256 digest of committed workflow content."
      t.jsonb :verification_files, null: false, default: [], comment: "Digest-addressed committed verification file references."
      t.string :lifecycle_gate, null: false
      t.jsonb :required_checks, null: false, default: []
      t.jsonb :advisory_checks, null: false, default: []
      t.string :status, null: false, default: "draft"
      t.datetime :approved_at
      t.timestamps
    end unless table_exists?(:apple_verification_workflow_revisions)
    unless index_exists?(:apple_verification_workflow_revisions, [ :project_id, :revision ], unique: true, name: "idx_apple_workflow_revisions_project_revision")
      add_index :apple_verification_workflow_revisions, [ :project_id, :revision ], unique: true, name: "idx_apple_workflow_revisions_project_revision"
    end
    add_index :apple_verification_workflow_revisions, [ :project_id, :status ] unless index_exists?(:apple_verification_workflow_revisions, [ :project_id, :status ])
    unless check_constraint_exists?(:apple_verification_workflow_revisions, name: "chk_apple_workflow_revisions_status")
      add_check_constraint :apple_verification_workflow_revisions, "status IN ('draft', 'approved', 'superseded', 'disabled')", name: "chk_apple_workflow_revisions_status"
    end
    unless check_constraint_exists?(:apple_verification_workflow_revisions, name: "chk_apple_workflow_revisions_gate")
      add_check_constraint :apple_verification_workflow_revisions, "lifecycle_gate IN ('agent_iteration', 'completion_verification', 'pull_request_verification')", name: "chk_apple_workflow_revisions_gate"
    end

    create_table :apple_verification_attempts, comment: "Apple verification attempt lifecycle and source provenance." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :agent_run, foreign_key: { on_delete: :nullify }
      t.references :apple_verification_workflow_revision, null: false, foreign_key: true
      t.references :apple_worker_profile, null: false, foreign_key: true
      t.string :source_digest, null: false
      t.string :commit_sha
      t.string :lifecycle_gate, null: false
      t.string :status, null: false, default: "queued"
      t.string :failure_classification
      t.integer :retry_number, null: false, default: 0
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end unless table_exists?(:apple_verification_attempts)
    unless index_exists?(:apple_verification_attempts, [ :project_id, :status, :created_at ], name: "idx_apple_attempts_project_status_created")
      add_index :apple_verification_attempts, [ :project_id, :status, :created_at ], name: "idx_apple_attempts_project_status_created"
    end
    unless check_constraint_exists?(:apple_verification_attempts, name: "chk_apple_attempts_status")
      add_check_constraint :apple_verification_attempts, "status IN ('queued', 'provisioning', 'running', 'succeeded', 'failed', 'cancelled', 'timed_out', 'unavailable')", name: "chk_apple_attempts_status"
    end
    unless check_constraint_exists?(:apple_verification_attempts, name: "chk_apple_attempts_gate")
      add_check_constraint :apple_verification_attempts, "lifecycle_gate IN ('agent_iteration', 'completion_verification', 'pull_request_verification')", name: "chk_apple_attempts_gate"
    end
    add_check_constraint :apple_verification_attempts, "retry_number >= 0", name: "chk_apple_attempts_retry_nonnegative" unless check_constraint_exists?(:apple_verification_attempts, name: "chk_apple_attempts_retry_nonnegative")

    create_table :apple_verification_waivers, comment: "One-attempt administrator waivers for required Apple verification checks." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :apple_verification_attempt, null: false, foreign_key: true, index: { unique: true }
      t.references :apple_verification_workflow_revision, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.string :source_digest, null: false
      t.string :lifecycle_gate, null: false
      t.jsonb :check_ids, null: false, default: []
      t.text :reason, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end unless table_exists?(:apple_verification_waivers)
    unless index_exists?(:apple_verification_waivers, :apple_verification_attempt_id, unique: true)
      remove_index :apple_verification_waivers, :apple_verification_attempt_id if index_exists?(:apple_verification_waivers, :apple_verification_attempt_id)
      add_index :apple_verification_waivers, :apple_verification_attempt_id, unique: true
    end
    unless check_constraint_exists?(:apple_verification_waivers, name: "chk_apple_waivers_gate")
      add_check_constraint :apple_verification_waivers, "lifecycle_gate IN ('agent_iteration', 'completion_verification', 'pull_request_verification')", name: "chk_apple_waivers_gate"
    end
  end
end
