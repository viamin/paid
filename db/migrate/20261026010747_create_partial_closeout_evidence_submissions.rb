class CreatePartialCloseoutEvidenceSubmissions < ActiveRecord::Migration[8.1]
  def change
    create_table :partial_closeout_evidence_submissions do |t|
      t.references :issue, null: false, foreign_key: true
      t.references :notification, null: false, foreign_key: true
      t.references :actor, null: false, foreign_key: { to_table: :users }
      t.string :criterion, null: false
      t.string :prerequisite_identity, null: false
      t.string :evidence_kind, null: false
      t.string :source_url
      t.bigint :source_record_id
      t.string :source_revision, null: false
      t.string :intent_revision, null: false
      t.string :outcome, null: false
      t.text :reason, null: false
      t.text :explanation, null: false
      t.jsonb :provenance, null: false, default: {}
      t.datetime :validated_at
      t.timestamps
    end

    add_index :partial_closeout_evidence_submissions,
      [ :notification_id, :prerequisite_identity, :source_revision ], unique: true,
      name: "index_partial_closeout_evidence_submissions_on_identity"
  end
end
