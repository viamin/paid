# frozen_string_literal: true

module Inbox
  # Derives a manual-review recovery from durable producers, never from the
  # prose stored for display.  A hold can have several causes; the first
  # actionable one is deliberately conservative so acknowledging one cause
  # cannot waive another.
  # @spec OPERATOR-INBOX-002D @spec ISSUE-REOPEN-REVIEW-005
  class ManualReviewRecovery
    Result = Data.define(:causes, :primary_cause, :action, :dependency_labels, :active_run) do
      def blocked_by_active_run? = active_run.present?
    end

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      causes = detected_causes
      Result.new(
        causes: causes.presence || [ :unknown ],
        primary_cause: primary_cause(causes),
        action: action_for(causes),
        dependency_labels: dependency_labels,
        active_run: active_run
      )
    end

    private

    attr_reader :issue

    def detected_causes
      [].tap do |causes|
        causes << :reopen_review if issue.reopen_review_pending?
        causes << :dependency if dependency_labels.any?
        causes << :scanner_recurrence if scanner_recurrence?
        causes << :enhancement if enhancement_provenance?
      end
    end

    def primary_cause(causes)
      %i[reopen_review dependency scanner_recurrence enhancement].find { |cause| causes.include?(cause) } || :unknown
    end

    def action_for(causes)
      return :record_intent_validation if causes.include?(:reopen_review)
      return :wait_for_dependency if causes.include?(:dependency)
      return :resume_remediation if causes.include?(:scanner_recurrence)
      return :retry_enhancement if causes.include?(:enhancement)

      :investigate
    end

    def dependency_labels
      @dependency_labels ||= Issues::CloseoutStatus.prerequisite_labels(issue)
    end

    def scanner_recurrence?
      issue.source == Issue::SYNTHETIC_CODE_SCANNING_SOURCE &&
        issue.code_scanning_remediation_attempts.latest_per_issue.where(status: "verification_failed").exists?
    end

    def enhancement_provenance?
      issue.needs_input_questions.present? || issue.agent_runs.where(goal: "enhance_issue").exists?
    end

    def active_run
      @active_run ||= issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(created_at: :asc).first
    end
  end
end
