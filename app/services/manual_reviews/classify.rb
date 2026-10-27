# frozen_string_literal: true

module ManualReviews
  # Classifies only durable state and known producer constants. A free-form
  # manual-review reason is evidence for the operator, never an instruction.
  # @spec ISSUE-REOPEN-REVIEW-005
  class Classify
    Cause = Data.define(:kind, :label, :action, :details)

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return Cause.new(kind: :reopen_review, label: "Reopened after closure", action: :record_decision, details: issue.reopen_reason) if issue.reopen_review_pending?
      return Cause.new(kind: :dependency, label: "Waiting on a dependency", action: :wait_for_dependency, details: dependency_refs) if dependencies_block?
      return Cause.new(kind: :scanner_recurrence, label: "Scanner-confirmed recurrence", action: :collect_evidence, details: nil) if scanner_recurrence?
      return Cause.new(kind: :enhancement_questions, label: "Enhancement questions", action: :answer_questions, details: nil) if issue.needs_input_questions.present?
      return Cause.new(kind: :enhancement_failure, label: "Enhancement analysis failed", action: :retry_analysis, details: nil) if enhancement_failure?

      Cause.new(kind: :unknown, label: "Unknown manual-review cause", action: :inspect, details: issue.manual_review_reason)
    end

    private

    attr_reader :issue

    def dependencies_block?
      issue.blocking_dependency_target_ids.exists? || issue.blocking_deployment_dependencies.exists? || issue.blocking_external_dependencies.exists?
    end

    def dependency_refs
      issue.blocking_issues.map { |dependency| "#{dependency.project.full_name}##{dependency.github_number}" } +
        issue.blocking_external_dependencies.map(&:external_ref)
    end

    def scanner_recurrence?
      issue.code_scanning_remediation_attempts.where(status: "verification_failed").exists?
    end

    def enhancement_failure?
      ([ Issue::ENHANCEMENT_PARSE_FAILURE_REASON ] + Issue::ENHANCEMENT_ROUND_LIMIT_REASONS).include?(issue.manual_review_reason)
    end
  end
end
