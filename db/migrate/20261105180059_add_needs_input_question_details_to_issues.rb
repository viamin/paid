# frozen_string_literal: true

class AddNeedsInputQuestionDetailsToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :needs_input_question_details, :jsonb,
      comment: "Structured clarifying-question payload persisted with needs_input_questions " \
               "(choices, recommendation, rationale, examples, evidence), so the inbox can " \
               "render the clarification detail without a per-issue GitHub API round-trip"
  end
end
