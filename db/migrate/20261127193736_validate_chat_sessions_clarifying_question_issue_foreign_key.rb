# frozen_string_literal: true

# @spec POSTGRESQL-PERSISTENCE-017
class ValidateChatSessionsClarifyingQuestionIssueForeignKey < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :chat_sessions, :issues, column: :clarifying_question_issue_id
  end
end
