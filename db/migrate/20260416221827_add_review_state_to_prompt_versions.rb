# frozen_string_literal: true

class AddReviewStateToPromptVersions < ActiveRecord::Migration[8.1]
  # Adds human review state to prompt versions. A null review_status means the
  # version was created outside the review workflow (manual edits, seeds, etc.)
  # and is not subject to the review gate. Evolved versions created while
  # prompts.requires_review is true start in "pending" and transition to
  # "approved" or "rejected" via the review UI.
  def change
    add_column :prompt_versions, :review_status, :string, limit: 20
    add_reference :prompt_versions, :reviewed_by_user,
      null: true, foreign_key: { to_table: :users, on_delete: :nullify }
    add_column :prompt_versions, :reviewed_at, :datetime
    add_column :prompt_versions, :review_notes, :text

    # Partial index: only versions participating in the review workflow are
    # indexed. Most historical versions have a null status and don't need to
    # appear in review queue queries.
    add_index :prompt_versions, [ :prompt_id, :review_status ],
      where: "review_status IS NOT NULL",
      name: "index_prompt_versions_on_prompt_and_review_status"
  end
end
