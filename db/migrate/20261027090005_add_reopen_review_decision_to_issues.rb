# frozen_string_literal: true

class AddReopenReviewDecisionToIssues < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :issues, :reopen_reviewed_at, :datetime
    add_reference :issues, :reopen_reviewed_by, index: { algorithm: :concurrently }
    add_column :issues, :reopen_review_decision, :string
    add_column :issues, :reopen_review_reason, :text
    add_column :issues, :reopen_review_revision, :datetime
  end
end
