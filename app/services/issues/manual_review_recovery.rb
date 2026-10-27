# frozen_string_literal: true

module Issues
  # Classifies only durable provenance. Free-form stop text is presentation,
  # never authority to clear a manual-review hold.
  # @spec ISSUE-REOPEN-REVIEW-005 OPERATOR-INBOX-002K
  class ManualReviewRecovery
    LEGACY_ENHANCEMENT_REASONS = [ "Round limit reached.", "Round limit reached" ].freeze
    Result = Data.define(:cause, :message, :action) do
      def enhancement? = cause == :enhancement
      def reopen_review? = cause == :reopen_review
      def dependency? = cause == :dependency
      def scanner_recurrence? = cause == :scanner_recurrence
      def unknown? = cause == :unknown
    end

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return reopen_review if issue.reopen_review_pending?
      return dependency if blocking_dependency?
      return scanner_recurrence if scanner_recurrence?
      return enhancement if enhancement_provenance?

      unknown
    end

    private

    attr_reader :issue

    def reopen_review = Result.new(cause: :reopen_review, action: :record_decision,
      message: "Validate the prior closure and remaining scope against the current issue revision.")

    def dependency = Result.new(cause: :dependency, action: :wait_for_dependency,
      message: "Work remains blocked by #{blocking_dependency_labels.join(', ')}. Resolve that work; Paid will reevaluate it.")

    def scanner_recurrence = Result.new(cause: :scanner_recurrence, action: :review_scanner_evidence,
      message: "A scanner-confirmed recurrence requires remediation evidence, not another enhancement pass.")

    def enhancement = Result.new(cause: :enhancement, action: :retry_enhancement,
      message: "Retry enhancement or answer the preserved clarifying questions.")

    def unknown = Result.new(cause: :unknown, action: :none,
      message: "Paid cannot identify the provenance of this hold. The hold remains in place for investigation.")

    def blocking_dependency?
      blocking_dependency_labels.any?
    end

    def blocking_dependency_labels
      @blocking_dependency_labels ||= (
        issue.blocking_issues.pluck(:github_number).map { |number| "##{number}" } +
        issue.blocking_deployment_dependencies.includes(:depends_on_issue).map { |dependency| "##{dependency.depends_on_issue.github_number}" } +
        issue.blocking_external_dependencies.map { |dependency| "#{dependency.depends_on_owner}/#{dependency.depends_on_repo}##{dependency.depends_on_number}" }
      ).uniq
    end

    def scanner_recurrence?
      issue.code_scanning_remediation_attempts.latest_per_issue.where(status: "verification_failed").exists?
    end

    def enhancement_provenance?
      issue.needs_input_questions.present? ||
        issue.agent_runs.where(goal: "enhance_issue").exists? ||
        LEGACY_ENHANCEMENT_REASONS.include?(issue.manual_review_reason) ||
        Inbox::PhaseOwnership::ENHANCEMENT_REASONS.match?(issue.manual_review_reason.to_s)
    end
  end
end
