# frozen_string_literal: true

class AddReopenReviewDecisionActorForeignKey < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_foreign_key :issues, :users, column: :reopen_review_decided_by_id, validate: false
  end

  def down
    remove_foreign_key :issues, column: :reopen_review_decided_by_id
  end
end
