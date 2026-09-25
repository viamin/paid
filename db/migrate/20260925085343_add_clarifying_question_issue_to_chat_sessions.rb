# frozen_string_literal: true

class AddClarifyingQuestionIssueToChatSessions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    unless column_exists?(:chat_sessions, :clarifying_question_issue_id)
      add_reference :chat_sessions, :clarifying_question_issue, index: false,
        comment: "Inbox issue whose clarifying questions this chat resolves."
    end
    unless index_exists?(:chat_sessions, :clarifying_question_issue_id, name: "index_chat_sessions_on_clarifying_question_issue_id")
      add_index :chat_sessions, :clarifying_question_issue_id, algorithm: :concurrently,
        name: "index_chat_sessions_on_clarifying_question_issue_id"
    end
    unless index_exists?(:chat_sessions, :clarifying_question_issue_id, name: "index_chat_sessions_one_open_clarifying_question_chat")
      add_index :chat_sessions, :clarifying_question_issue_id, algorithm: :concurrently,
        unique: true,
        where: "clarifying_question_issue_id IS NOT NULL AND status != 'archived'",
        name: "index_chat_sessions_one_open_clarifying_question_chat"
    end
  end

  def down
    if index_exists?(:chat_sessions, :clarifying_question_issue_id, name: "index_chat_sessions_one_open_clarifying_question_chat")
      remove_index :chat_sessions, :clarifying_question_issue_id,
        name: "index_chat_sessions_one_open_clarifying_question_chat", algorithm: :concurrently
    end
    if index_exists?(:chat_sessions, :clarifying_question_issue_id, name: "index_chat_sessions_on_clarifying_question_issue_id")
      remove_index :chat_sessions, :clarifying_question_issue_id,
        name: "index_chat_sessions_on_clarifying_question_issue_id", algorithm: :concurrently
    end
    remove_reference :chat_sessions, :clarifying_question_issue, index: false if column_exists?(:chat_sessions, :clarifying_question_issue_id)
  end
end
