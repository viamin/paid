# frozen_string_literal: true

class AddClarifyingQuestionIssueToChatSessions < ActiveRecord::Migration[8.1]
  def change
    add_reference :chat_sessions, :clarifying_question_issue,
      foreign_key: { to_table: :issues },
      comment: "Inbox issue whose clarifying questions this chat resolves."

    add_index :chat_sessions, :clarifying_question_issue_id,
      unique: true,
      where: "clarifying_question_issue_id IS NOT NULL AND status != 'archived'",
      name: "index_chat_sessions_one_open_clarifying_question_chat"
  end
end
