# frozen_string_literal: true

class AddReopenReviewValidatedByForeignKeyToIssues < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_foreign_key :issues, :users, column: :reopen_review_validated_by_id, validate: false
  end
end
