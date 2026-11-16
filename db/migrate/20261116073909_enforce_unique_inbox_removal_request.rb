# frozen_string_literal: true

class EnforceUniqueInboxRemovalRequest < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :inbox_removals, %i[user_id request_key], unique: true,
      name: "index_inbox_removals_on_user_and_request", algorithm: :concurrently,
      comment: "One durable personal suppression per user and Inbox request."
  end
end
