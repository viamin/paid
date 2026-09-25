# frozen_string_literal: true

class AddClarifyingQuestionIssueForeignKeyToChatSessions < ActiveRecord::Migration[8.1]
  def change
    return if foreign_key_exists?(:chat_sessions, :issues, column: :clarifying_question_issue_id)

    add_foreign_key :chat_sessions, :issues, column: :clarifying_question_issue_id, validate: false
  end
end
