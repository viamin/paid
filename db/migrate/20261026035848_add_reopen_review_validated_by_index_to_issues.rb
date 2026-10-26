# frozen_string_literal: true

class AddReopenReviewValidatedByIndexToIssues < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :issues, :reopen_review_validated_by_id, algorithm: :concurrently
  end
end
