class CreateSharedDeliveryEvidenceAssociations < ActiveRecord::Migration[8.1]
  def change
    create_table :shared_delivery_evidence_associations,
      comment: "Operator-authorized, revision-bound use of a merged PR as delivery evidence for another issue." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :issue, null: false, foreign_key: true
      t.references :pull_request, null: false, foreign_key: { to_table: :issues }
      t.references :authorized_by, null: false, foreign_key: { to_table: :users }
      t.string :pull_request_url, null: false
      t.string :revision, limit: 40, null: false
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :shared_delivery_evidence_associations, :issue_id, unique: true,
      where: "revoked_at IS NULL", name: "index_shared_delivery_evidence_active_per_issue"
  end
end
