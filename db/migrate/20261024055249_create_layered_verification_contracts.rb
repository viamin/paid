class CreateLayeredVerificationContracts < ActiveRecord::Migration[8.1]
  def change
    create_table :layered_verification_obligations do |t|
      t.references :project, null: false, foreign_key: true
      t.string :framework, null: false
      t.string :external_identity, null: false
      t.string :external_revision
      t.text :scope_description, null: false
      t.string :approval_state, null: false, default: "unresolved"
      t.string :approved_revision_reference
      t.references :superseded_by, foreign_key: { to_table: :layered_verification_obligations }
      t.references :change_intent, foreign_key: true
      t.datetime :synced_at
      t.timestamps
    end

    add_index :layered_verification_obligations,
      [ :project_id, :framework, :external_identity ],
      unique: true,
      name: "index_layered_verification_obligations_identity"

    create_table :layered_verification_correspondence_claims do |t|
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations }
      t.string :claim_type, null: false
      t.text :source_reference, null: false
      t.text :target_reference, null: false
      t.text :abstraction_boundaries, null: false
      t.text :assumptions, null: false
      t.timestamps
    end

    create_table :layered_verification_check_results do |t|
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations }
      t.references :correspondence_claim, foreign_key: { to_table: :layered_verification_correspondence_claims }
      t.references :agent_run, foreign_key: true
      t.string :producer, null: false
      t.string :execution_state, null: false
      t.string :obligation_coverage, null: false
      t.jsonb :input_revision, null: false, default: {}
      t.string :evidence_ref
      t.jsonb :evidence_summary, null: false, default: {}
      t.jsonb :agent_reported, null: false, default: {}
      t.jsonb :recorder_verified, null: false, default: {}
      t.jsonb :cost, null: false, default: {}
      t.text :limitations, null: false
      t.timestamps
    end
  end
end
