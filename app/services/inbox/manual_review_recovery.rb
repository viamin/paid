# frozen_string_literal: true

module Inbox
  # Classifies a parked issue from durable state rather than treating every
  # manual-review row as a request to restart enhancement. This is deliberately
  # structural: opaque legacy reasons remain unknown instead of being guessed.
  # @spec OPERATOR-INBOX-002L ISSUE-REOPEN-REVIEW-005
  class ManualReviewRecovery
    Blocker = Data.define(:label, :url, :issue)
    Result = Data.define(:cause, :action, :blockers, :active_run) do
      def active? = active_run.present?
    end

    ENHANCEMENT_REASON_MARKERS = [
      "enhancement re-evaluation",
      "enhancement agent's structured output",
      "enhancement output",
      "enhancement transport",
      "Round limit reached",
      "could not validate the enhancement",
      "Structured output failed validation"
    ].freeze

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      Result.new(cause:, action:, blockers:, active_run: unfinished_run)
    end

    private

    attr_reader :issue

    def cause
      return :reopen_review if issue.reopen_review_pending?
      return :dependency if blockers.any?
      return :scanner_recurrence if issue.source == Issue::SYNTHETIC_CODE_SCANNING_SOURCE
      return :enhancement if enhancement_provenance?

      :unknown
    end

    def action
      {
        reopen_review: :record_reopen_validation,
        dependency: :wait_for_dependency,
        scanner_recurrence: :collect_scanner_evidence,
        enhancement: :retry_enhancement,
        unknown: :none
      }.fetch(cause)
    end

    def blockers
      @blockers ||= local_blockers + deployment_blockers + external_blockers
    end

    def local_blockers
      issue.blocking_issues.map { |blocker| Blocker.new(label: "##{blocker.github_number} #{blocker.title}", url: blocker.github_url, issue: blocker) }
    end

    def deployment_blockers
      issue.blocking_deployment_dependencies.includes(:depends_on_issue).map do |dependency|
        blocker = dependency.depends_on_issue
        Blocker.new(label: "##{blocker.github_number} #{blocker.title} (awaiting deployment)", url: blocker.github_url, issue: blocker)
      end
    end

    def external_blockers
      issue.blocking_external_dependencies.map do |dependency|
        Blocker.new(label: "#{dependency.external_ref} (external dependency)", url: "https://github.com/#{dependency.external_ref.sub("#", "/issues/")}", issue: nil)
      end
    end

    def enhancement_provenance?
      issue.needs_input_questions.present? ||
        issue.manual_review_reason == Issue::REOPEN_REVIEW_VALIDATED_REASON ||
        issue.agent_runs.where(goal: "enhance_issue").exists? ||
        ENHANCEMENT_REASON_MARKERS.any? { |marker| issue.manual_review_reason.to_s.include?(marker) }
    end

    def unfinished_run
      issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(created_at: :desc, id: :desc).first
    end
  end
end
