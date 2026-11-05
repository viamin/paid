# frozen_string_literal: true

class CreateBoundedDelegatedActions < ActiveRecord::Migration[8.1]
  def change
    create_table :bounded_delegated_actions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :issue, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.references :revoked_by, foreign_key: { to_table: :users }
      t.string :action, null: false
      t.string :status, null: false, default: "active"
      t.jsonb :evidence, null: false, default: {}
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.timestamps
    end

    add_index :bounded_delegated_actions, [ :project_id, :issue_id, :action ],
      name: "index_bounded_actions_on_project_issue_action"
    add_index :bounded_delegated_actions, [ :status, :expires_at ],
      name: "index_bounded_actions_on_status_and_expiry"
  end
end
