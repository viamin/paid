# frozen_string_literal: true

module Inbox
  # Resolves only the inbox context sections the chat explicitly requests.
  # Nothing here is inserted into a session prompt at open time.
  # @spec QUESTION-EXPLORATION-014
  class ChatContext
    SECTIONS = %w[work_item comments review_comments labels queue_metadata agent_run_output record partial_closeout].freeze

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

    # Record-backed lanes are not necessarily issue-backed. Resolve them when
    # requested, scoped to the chat's project, rather than trusting the audit
    # snapshot or adding their contents to the opening prompt.
    # @spec OPERATOR-INBOX-002I
    def record
      case inbox_kind
      when Queue::PLAN_REVIEW_KIND then decomposition_decision_context
      when Queue::ACTION_REQUIRED_KIND then notification_context
      when Queue::INTENT_CONFORMANCE_KIND then intent_conformance_context
      when Queue::FEATURE_DECISION_KIND then feature_intent_context
      when Queue::CHANGE_INTENT_DRAFT_KIND then change_intent_context
      when Queue::PARTIAL_CLOSEOUT_KIND then partial_closeout
      when Queue::MERGE_APPROVAL_KIND, Queue::ESCALATED_PR_KIND then pull_request_context
      else work_item
      end
    end

    # @spec PARTIAL-CLOSEOUT-010
    def partial_closeout
      return {} unless inbox_kind == Queue::PARTIAL_CLOSEOUT_KIND && issue

      status = Issues::CloseoutStatus.call(issue)
      {
        issue: work_item,
        acceptance_criteria: issue.body,
        recorded_outcome: status.outcome,
        scheduling_blocker: status.reason,
        merged_pull_requests: status.evidence.merged_prs.map { |pull_request|
          { number: pull_request.number, url: pull_request.url, run_id: pull_request.run_id, terminal_at: pull_request.terminal_at }
        },
        unresolved_prerequisites: status.unresolved_prerequisites,
        continuation_requests: IssueContinuationRequest.where(issue:).order(created_at: :desc).limit(5).map { |request|
          request.attributes.slice("id", "status", "reason", "created_at", "updated_at")
        },
        resolution: issue.attributes.slice("closeout_resolved_at", "closeout_resolution_digest", "closeout_resolved_by_id")
      }
    end

    def issue
      return @issue if defined?(@issue)

      @issue = chat_session.project.issues.find_by(id: chat_session.inbox_item_metadata["issue_id"])
    end

    def inbox_kind
      chat_session.inbox_item_metadata["kind"]
    end

    def record_id
      chat_session.inbox_item_metadata["record_id"]
    end

    def decomposition_decision_context
      record_attributes(DecompositionDecision.find_by(id: record_id, project: chat_session.project),
        "decision_key", "workflow_name", "workflow_id", "decision_type", "outcome", "plan_data")
    end

    def notification_context
      notification = Notification.find_by(id: record_id, account: chat_session.account)
      return {} unless notification&.resolved_project == chat_session.project

      record_attributes(notification,
        "title", "source", "metadata", "action_url", "subject_type", "subject_id")
    end

    def intent_conformance_context
      snapshot = issue && Inbox::IntentConformance.call(issue)
      return {} unless snapshot

      { issue: work_item, summary: snapshot.summary, verdict: snapshot.verdict&.attributes, decisions: snapshot.decisions.map(&:attributes) }
    end

    def feature_intent_context
      feature_intent = FeatureIntent.find_by(id: record_id, project: chat_session.project)
      return {} unless feature_intent

      record_attributes(feature_intent, "title", "status", "brief", "acceptance_criteria", "criteria_clarity_explanation").merge(
        decisions: feature_intent.feature_intent_decisions.map(&:attributes),
        design_pull_requests: feature_intent.feature_intent_design_prs.map(&:attributes)
      )
    end

    def change_intent_context
      record_attributes(ChangeIntent.find_by(id: record_id, project: chat_session.project),
        "title", "intent", "behavior", "constraints", "decisions_made", "status", "requested_changes_reason")
    end

    def pull_request_context
      return {} unless issue

      {
        pull_request: work_item,
        review_phase: issue.pr_review_phase,
        blockers: issue.auto_merge_blockers,
        agent_runs: agent_run_output
      }
    end

    def record_attributes(record, *fields)
      return {} unless record

      record.attributes.slice("id", *fields)
    end

    def github_client
      @github_client ||= chat_session.project.client
    end
  end
end
