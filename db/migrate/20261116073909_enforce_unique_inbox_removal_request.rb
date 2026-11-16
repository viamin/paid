# frozen_string_literal: true

class EnforceUniqueInboxRemovalRequest < ActiveRecord::Migration[8.1] # @spec INBOX-PHASE-RELEVANCE-008
  INDEX_NAME = "index_inbox_removals_on_user_and_request"

  disable_ddl_transaction!

  def up
    deduplicate_removals
    add_unique_index
  rescue ActiveRecord::StatementInvalid => error
    raise unless error.cause.is_a?(PG::UniqueViolation)

    deduplicate_removals
    remove_index :inbox_removals, name: INDEX_NAME, algorithm: :concurrently if index_exists?(:inbox_removals, name: INDEX_NAME)
    add_unique_index
  end

  def down
    remove_index :inbox_removals, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end

  private

  def add_unique_index
    add_index :inbox_removals, %i[user_id request_key], unique: true,
      name: INDEX_NAME, algorithm: :concurrently,
      comment: "One durable personal suppression per user and Inbox request."
  end

  def deduplicate_removals
    safety_assured do
      execute <<~SQL.squish
        DELETE FROM inbox_removals
        WHERE id IN (
          SELECT id
          FROM (
            SELECT id, ROW_NUMBER() OVER (
              PARTITION BY user_id, request_key
              ORDER BY updated_at DESC, id DESC
            ) AS position
            FROM inbox_removals
          ) ranked_removals
          WHERE position > 1
        )
      SQL
    end
  end
end
