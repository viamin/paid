# frozen_string_literal: true

class CreateNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :notifications do |t|
      t.bigint :account_id, null: false
      t.bigint :user_id
      t.string :subject_type
      t.bigint :subject_id
      t.string :source, null: false
      t.integer :severity, default: 0, null: false
      t.string :title, null: false
      t.text :description
      t.jsonb :metadata, default: {}, null: false
      t.string :action_url
      t.string :nav_section
      t.datetime :read_at
      t.datetime :dismissed_at
      t.datetime :resolved_at

      t.timestamps
    end

    add_index :notifications, [ :account_id, :read_at, :dismissed_at ], name: "index_notifications_on_unread"
    add_index :notifications, [ :account_id, :source, :subject_type, :subject_id ],
      unique: true, name: "index_notifications_on_dedup"
    add_index :notifications, [ :account_id, :nav_section, :read_at ], name: "index_notifications_on_badge"
    add_index :notifications, [ :subject_type, :subject_id ], name: "index_notifications_on_subject"

    add_foreign_key :notifications, :accounts
    add_foreign_key :notifications, :users
  end
end
