# frozen_string_literal: true

class AddPartialUniqueIndexForAccountWideNotifications < ActiveRecord::Migration[8.1]
  def change
    # PostgreSQL treats NULL as distinct in unique indexes, so the existing
    # index_notifications_on_dedup (which includes user_id) does not prevent
    # duplicate account-wide notifications where user_id IS NULL.
    # Add a partial unique index covering the NULL case.
    add_index :notifications,
      [ :account_id, :source, :subject_type, :subject_id ],
      unique: true,
      where: "user_id IS NULL",
      name: "index_notifications_on_dedup_account_wide"
  end
end
