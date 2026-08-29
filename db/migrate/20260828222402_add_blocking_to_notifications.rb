# frozen_string_literal: true

class AddBlockingToNotifications < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    unless column_exists?(:notifications, :blocking)
      add_column :notifications, :blocking, :boolean,
        default: false,
        null: false,
        comment: "True when the notification's error state cannot self-resolve and requires human action to resume work."
    end

    if index_exists?(:notifications, name: "index_notifications_on_badge")
      remove_index :notifications, name: "index_notifications_on_badge", algorithm: :concurrently
    end

    add_index :notifications,
      [ :account_id, :blocking, :read_at ],
      where: "dismissed_at IS NULL AND resolved_at IS NULL",
      name: "index_notifications_on_badge",
      if_not_exists: true,
      algorithm: :concurrently
  end
end
