# frozen_string_literal: true

class FixNotificationsDedupIndexAddUserId < ActiveRecord::Migration[8.1]
  def change
    remove_index :notifications, name: "index_notifications_on_dedup"
    add_index :notifications, [ :account_id, :user_id, :source, :subject_type, :subject_id ],
      unique: true, name: "index_notifications_on_dedup"
  end
end
