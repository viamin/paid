# frozen_string_literal: true

module ManualReviews
  # Selects a recovery action from durable manual-review provenance. This is
  # intentionally structural: a stop reason is operator-facing evidence, not
  # a classifier for guessing which workflow should run next.
  class Recovery
    # These are the stable producer messages written by the enhancement stop
    # paths. They retain legacy provenance without treating arbitrary prose as
    # an authorization to restart enhancement.
    ENHANCEMENT_STOP_MARKERS = [
      "enhancement re-evaluation rounds",
      "could not validate the enhancement agent's structured output",
      "manual review is needed before enhancement can continue"
    ].freeze
    TECHNICAL_STOP_MARKERS = [ "structured output", "enhancement transport failed" ].freeze
    Plan = Data.define(:cause, :action, :goal, :message, :dependencies, :active_run) do
      def actionable? = action.present?
    end

    def self.for(...) = new(...).for

    def initialize(issue:)
      @issue = issue
    end

    # @spec OPERATOR-INBOX-002K
    def for
      return Plan.new(cause: :reopen_review, action: :record_reopen_decision, goal: nil,
        message: "Validate the prior closure and current scope before choosing a continuation.", dependencies: [], active_run: active_run) if issue.reopen_review_pending?
      return dependency_plan if dependencies.any?
      return scanner_plan if scanner_blockers.any?
      return active_plan if active_run
      return enhancement_plan if issue.needs_input_questions.present? || known_enhancement_stop?
      return technical_plan if known_technical_stop?
      return technical_plan if enhancement_failure?

      Plan.new(cause: :unknown, action: nil, goal: nil,
        message: "Paid retained this manual-review hold, but its producer is unknown. Inspect the recorded reason before changing work.",
        dependencies: [], active_run: nil)
    end

    private

    attr_reader :issue

    def dependency_plan
      Plan.new(cause: :dependency, action: nil, goal: nil,
        message: "Work is waiting on an unresolved dependency. Resolving or acknowledging this review does not waive that dependency.",
        dependencies:, active_run: active_run)
    end

    def scanner_plan
      Plan.new(cause: :scanner_recurrence, action: :resume_implementation, goal: "create_pr",
        message: "The scanner confirmed the finding recurs. This action resumes remediation implementation; it does not retry enhancement.",
        dependencies: [], active_run: active_run)
    end

    def active_plan
      Plan.new(cause: :active_work, action: nil, goal: nil,
        message: "Run ##{active_run.id} is already #{active_run.status}. Reuse or reconcile that work before starting another recovery action.",
        dependencies: [], active_run: active_run)
    end

    def enhancement_plan
      Plan.new(cause: :enhancement, action: :retry_enhancement, goal: "enhance_issue",
        message: "Answer the preserved questions or retry enhancement analysis.", dependencies: [], active_run: nil)
    end

    def technical_plan
      Plan.new(cause: :technical_failure, action: :retry_enhancement, goal: "enhance_issue",
        message: "The prior enhancement run failed technically. This action retries analysis; it does not record a closure decision.",
        dependencies: [], active_run: nil)
    end

    def dependencies
      @dependencies ||= issue.blocking_issues.to_a + issue.blocking_deployment_dependencies.to_a + issue.blocking_external_dependencies.to_a
    end

    def scanner_blockers
      @scanner_blockers ||= Issues::CloseoutStatus.scanner_verification_blockers(issue)
    end

    def active_run
      @active_run ||= issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(created_at: :asc).first
    end

    def enhancement_failure?
      issue.agent_runs.where(goal: "enhance_issue", status: AgentRun::FAILURE_STATUSES).exists?
    end

    def known_enhancement_stop?
      reason = issue.manual_review_reason.to_s.downcase
      ENHANCEMENT_STOP_MARKERS.any? { |marker| reason.include?(marker) }
    end

    def known_technical_stop?
      reason = issue.manual_review_reason.to_s.downcase
      TECHNICAL_STOP_MARKERS.any? { |marker| reason.include?(marker) }
    end
  end
end
