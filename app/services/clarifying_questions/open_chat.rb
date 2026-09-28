# frozen_string_literal: true

module ClarifyingQuestions
  class OpenChat
    def self.call(...)
      new(...).call
    end

    def initialize(issue:, user:)
      @issue = issue
      @user = user
    end

    def call
      existing_chat || open_new_chat
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    private

    attr_reader :issue, :user

    # @spec QUESTION-EXPLORATION-001
    def existing_chat
      chat = ChatSession.where(clarifying_question_issue: issue).order(updated_at: :desc).first
      return unless chat

      ChatSessions::Unarchive.call(chat_session: chat) if chat.archived?
      chat.update!(title:) unless chat.title == title
      chat
    end

    # The pending questions are resolved before ChatSessions::Create opens its
    # insert transaction: ClarifyingQuestions::Load performs GitHub I/O (its
    # reconcile path can even post to GitHub), which must never hold a
    # database connection or the partial unique index's insert while it runs.
    # The resolved questions are snapshotted into session metadata so the
    # system prompt renders them without another network round trip.
    # @spec QUESTION-EXPLORATION-001
    def open_new_chat
      questions = ClarifyingQuestions::Load.call(project: issue.project, issue: issue)
      ChatSessions::Create.call(
        account: issue.project.account,
        user: user,
        project_id: issue.project_id,
        title:,
        metadata: {
          "clarifying_question_issue_id" => issue.id,
          "clarifying_questions" => questions
        },
        clarifying_question_issue: issue
      )
    end

    def title
      "Clarifying questions for #{issue.project.full_name}##{issue.github_number}"
    end
  end
end
