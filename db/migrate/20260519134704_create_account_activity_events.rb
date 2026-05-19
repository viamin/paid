# frozen_string_literal: true

class CreateAccountActivityEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :account_activity_events do |t|
      t.references :account, null: false, foreign_key: true, comment: "Account whose administration history this event belongs to."
      t.bigint :actor_id, comment: "User who performed the action, when available."
      t.string :action, null: false, comment: "Stable action key for the account administration event."
      t.string :subject_type, comment: "Polymorphic subject type affected by the action."
      t.bigint :subject_id
      t.jsonb :metadata, null: false, default: {}, comment: "Structured event details for UI rendering and audits."

      t.timestamps
    end

    add_foreign_key :account_activity_events, :users, column: :actor_id, validate: false
    add_index :account_activity_events, [ :account_id, :created_at ]
    add_index :account_activity_events, [ :subject_type, :subject_id ]
  end
end
