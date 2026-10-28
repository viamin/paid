# frozen_string_literal: true

module Inbox
  # Selects a recovery action from durable producer evidence.  The free-form
  # reason is deliberately display-only: changing prose must never change what
  # work Paid starts next.
  # @spec OPERATOR-INBOX-002D OPERATOR-INBOX-002L ISSUE-REOPEN-REVIEW-005
  class ManualReviewRecovery
    Plan = Data.define(:cause, :action, :description, :dependencies) do
      def enhancement? = action == :enhance
      def waiting_for_dependency? = action == :wait_for_dependency
      def unknown? = action == :investigate
    end

    def self.for(issue) = new(issue).plan

    def initialize(issue)
      @issue = issue
    end

    def plan
      return reopen_plan if issue.reopen_review_pending?
      return dependency_plan if dependencies.any?
      return scanner_plan if scanner_recurrence?
      return enhancement_plan if enhancement_stop?

      unknown_plan
    end

    private

    attr_reader :issue

    def reopen_plan
      Plan.new(
        cause: :reopen_review,
        action: :validate_intent,
        description: "Record an authorized intent-validation decision before choosing follow-up work.",
        dependencies: []
      )
    end

    def dependency_plan
      Plan.new(
        cause: :dependency,
        action: :wait_for_dependency,
        description: "Work remains blocked by an unresolved dependency. Paid will reevaluate it when that dependency resolves.",
        dependencies:
      )
    end

    def scanner_plan
      Plan.new(
        cause: :scanner_recurrence,
        action: :continue_remediation,
        description: "The scanner confirmed the finding recurred. Review the evidence and authorize remediation through the supported closeout recovery action.",
        dependencies: []
      )
    end

    def enhancement_plan
      Plan.new(
        cause: :enhancement,
        action: :enhance,
        description: "Retry analysis with a manual enhancement run.",
        dependencies: []
      )
    end

    def unknown_plan
      Plan.new(
        cause: :unknown,
        action: :investigate,
        description: "Paid could not identify the producer of this hold. Review its recorded reason before selecting new work.",
        dependencies: []
      )
    end

    def dependencies
      @dependencies ||= issue.issue_dependencies.includes(:depends_on_issue).select do |dependency|
        external_dependency_blocking?(dependency) || local_dependency_blocking?(dependency)
      end
    end

    def external_dependency_blocking?(dependency)
      dependency.external? && IssueDependency.still_blocking_external_for_account(issue.project.account_id)
        .where(id: dependency.id).exists?
    end

    def local_dependency_blocking?(dependency)
      target = dependency.depends_on_issue
      return false unless target
      return false if issue.parent_issue_id == target.id
      return true if dependency.deployment_pending?

      target.github_state == "open" && !target.paid_state.in?(Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES)
    end

    def scanner_recurrence?
      issue.code_scanning_remediation_attempts.where(status: "verification_failed").exists?
    end

    def enhancement_stop?
      issue.needs_input_questions.present? || issue.agent_runs.where(goal: "enhance_issue").exists?
    end
  end
end
