# frozen_string_literal: true

module ClarifyingQuestions
  class OpenChat
    TITLE = "Clarifying questions"

    def self.call(...)
      new(...).call
    end

    def initialize(issue:, user:)
      @issue = issue
      @user = user
    end

    def call
      ChatSession.transaction do
        existing_chat || create_chat
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    private

    attr_reader :issue, :user

    def existing_chat
      chat = ChatSession.where(clarifying_question_issue: issue).order(updated_at: :desc).first
      return unless chat

      ChatSessions::Unarchive.call(chat) if chat.archived?
      chat
    end

    def create_chat
      ChatSessions::Create.call(
        account: issue.project.account,
        user: user,
        project_id: issue.project_id,
        title: TITLE,
        metadata: { "clarifying_question_issue_id" => issue.id },
        clarifying_question_issue: issue
      )
    end
  end
end
