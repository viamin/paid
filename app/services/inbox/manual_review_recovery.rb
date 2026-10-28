# frozen_string_literal: true

module Inbox
  # Classifies a manual-review issue from persisted producer evidence. This is
  # deliberately structural: the Inbox must not infer a cause from prose.
  # @spec OPERATOR-INBOX-002D
  class ManualReviewRecovery
    ENHANCEMENT_REASON_MARKERS = [
      "Round limit reached.",
      "enhancement re-evaluation rounds",
      "enhancement agent",
      "Structured output"
    ].freeze
    Cause = Data.define(:key, :label, :explanation, :action, :dependencies, :run)
    Dependency = Data.define(:label, :url)

    def self.call(issue:) = new(issue).call

    def initialize(issue)
      @issue = issue
    end

    def call
      return reopen_review if issue.reopen_review_pending?
      return dependency if blocking_dependencies.any?
      return scanner if scanner_recurrence?
      return enhancement if latest_run&.enhance_issue_goal?
      return enhancement if enhancement_reason?
      return technical_failure if latest_run&.failed?

      unknown
    end

    private

    attr_reader :issue

    def reopen_review
      cause("reopen_review", "Reopen review", "The issue was reopened after its prior closure.",
        "validate_reopen", [])
    end

    def dependency
      cause("dependency", "Unresolved dependency", "Required prerequisite work is still open.",
        "wait_for_dependency", dependency_links)
    end

    def scanner
      cause("scanner", "Scanner recurrence", "The scanner still reports the finding after remediation.",
        "collect_scanner_evidence", [])
    end

    def enhancement
      cause("enhancement", "Enhancement recovery", "The enhancement run stopped before implementation could continue.",
        "retry_enhancement", [])
    end

    def technical_failure
      cause("technical_failure", "Technical recovery", "The last run failed before supported work could continue.",
        "retry_analysis", [])
    end

    def unknown
      cause("unknown", "Unknown manual-review cause", "Paid could not classify this hold from persisted provenance.",
        "investigate", [])
    end

    def cause(key, label, explanation, action, dependencies)
      Cause.new(key:, label:, explanation:, action:, dependencies:, run: latest_run)
    end

    def latest_run
      @latest_run ||= issue.agent_runs.order(created_at: :desc, id: :desc).first
    end

    def blocking_dependencies
      @blocking_dependencies ||= begin
        status = Issues::CloseoutStatus.call(issue)
        status.unresolved_prerequisites
      end
    end

    def scanner_recurrence?
      return false unless issue.source == Issue::SYNTHETIC_CODE_SCANNING_SOURCE

      Issues::CloseoutStatus.scanner_verification_blockers(issue).any?
    end

    def enhancement_reason?
      ENHANCEMENT_REASON_MARKERS.any? { |marker| issue.manual_review_reason.to_s.include?(marker) }
    end

    def dependency_links
      labels = blocking_dependencies
      issue.issue_dependencies.includes(:depends_on_issue).filter_map do |dependency|
        label, url = dependency_reference(dependency)
        Dependency.new(label:, url:) if label && labels.include?(label)
      end
    end

    def dependency_reference(dependency)
      if dependency.depends_on_issue
        [ "##{dependency.depends_on_issue.github_number}", dependency.depends_on_issue.github_url ]
      elsif dependency.external?
        [ dependency.external_ref, "https://github.com/#{dependency.external_ref.sub('#', '/issues/')}" ]
      end
    end
  end
end
