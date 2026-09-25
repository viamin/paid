# frozen_string_literal: true

module Inbox
  # Resolves only the inbox context sections the chat explicitly requests.
  # Nothing here is inserted into a session prompt at open time.
  # @spec QUESTION-EXPLORATION-014
  class ChatContext
    SECTIONS = %w[work_item comments review_comments labels queue_metadata agent_run_output].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(chat_session:, user:, sections:, github_client: nil)
      @chat_session = chat_session
      @user = user
      @sections = Array(sections).map(&:to_s)
      @github_client = github_client
    end

    def call
      authorize!
      validate_sections!
      sections.index_with { |section| send(section) }
    end

    private

    attr_reader :chat_session, :sections, :user

    def authorize!
      raise Pundit::NotAuthorizedError unless chat_session.interactive_inbox_chat?
      raise Pundit::NotAuthorizedError unless chat_session.created_by == user
      raise Pundit::NotAuthorizedError unless InteractiveChatAccess.allowed?(user:, project: chat_session.project)
    end

    def validate_sections!
      invalid_sections = sections - SECTIONS
      return if invalid_sections.empty?

      raise ArgumentError, "unknown inbox context sections: #{invalid_sections.join(', ')}"
    end

    def work_item
      return {} unless issue

      {
        id: issue.id,
        number: issue.github_number,
        title: issue.title,
        body: issue.body,
        type: issue.is_pull_request? ? "pull_request" : "issue"
      }
    end

    def comments
      return [] unless issue

      trusted_issue_comments.map do |comment|
        { id: comment.id, author: comment.user&.login, body: comment.body, created_at: comment.created_at }
      end
    end

    def review_comments
      return [] unless issue&.is_pull_request?

      trusted_review_comments.map do |comment|
        { id: comment[:id], author: comment[:user_login], body: comment[:body], path: comment[:path], line: comment[:line] }
      end
    end

    def trusted_issue_comments
      Prompts::BuildForIssue.fetch_trusted_comments(
        github_client:,
        repo: chat_session.project.full_name,
        number: issue.github_number,
        project: chat_session.project
      )
    end

    def trusted_review_comments
      github_client.pull_request_review_comments(chat_session.project.full_name, issue.github_number).select do |comment|
        PromptAssembly::Trust.human_trusted?(chat_session.project, comment[:user_login])
      end
    end

    def labels
      issue ? Array(issue.labels) : []
    end

    def queue_metadata
      chat_session.inbox_item_metadata
    end

    def agent_run_output
      return [] unless issue

      chat_session.project.agent_runs.where(issue:).order(created_at: :desc).limit(5).includes(:agent_run_logs).map do |run|
        { id: run.id, status: run.status, output: run.agent_run_logs.map(&:content) }
      end
    end

    def issue
      return @issue if defined?(@issue)

      @issue = chat_session.project.issues.find_by(id: chat_session.inbox_item_metadata["issue_id"])
    end

    def github_client
      @github_client ||= chat_session.project.client
    end
  end
end
