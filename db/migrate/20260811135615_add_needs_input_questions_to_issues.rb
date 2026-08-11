# frozen_string_literal: true

class AddNeedsInputQuestionsToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :needs_input_questions, :jsonb,
      comment: "Parsed clarifying questions persisted when a needs-input comment is posted, " \
               "so the dashboard queue can render without a per-issue GitHub API round-trip"
  end
end
