# frozen_string_literal: true

class AddClosedAtToIssues < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:issues, :closed_at)

    add_column :issues,
      :closed_at,
      :datetime,
      comment: "When github_state first transitioned to 'closed'. Distinct from updated_at " \
               "and github_updated_at so unrelated sync metadata (label edits, comments) " \
               "cannot move the resolution timestamp used by epic re-audit eligibility."
  end

  def down
    remove_column :issues, :closed_at if column_exists?(:issues, :closed_at)
  end
end
