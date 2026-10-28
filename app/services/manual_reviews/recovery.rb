# frozen_string_literal: true

module ManualReviews
  # Classifies a parked issue from durable domain provenance. The manual-review
  # reason remains operator-visible context; it is not a protocol to parse.
  # @spec OPERATOR-INBOX-002D
  class Recovery
    Result = Data.define(:cause, :action, :message, :dependencies) do
      def enhancement_retry?
        action == :retry_enhancement
      end
    end

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return reopen_review if issue.reopen_review_pending?
      return dependency_wait if dependencies.any?
      return scanner_recurrence if scanner_recurrence?
      return enhancement_questions if issue.needs_input_questions.present?
      return enhancement_failure if enhancement_failure?

      unknown
    end

    private

    attr_reader :issue

    def dependencies
      @dependencies ||= issue.blocking_issues.to_a
    end

    def reopen_review
      result(:reopen_review, :record_reopen_decision,
        "Validate the prior closure and current scope before choosing a continuation.")
    end

    def dependency_wait
      result(:dependency_wait, :wait_for_dependency,
        "Work is waiting for #{dependency_labels}; resolve the dependency before retrying.", dependencies)
    end

    def scanner_recurrence
      result(:scanner_recurrence, :authorize_remediation,
        "Scanner evidence confirmed that remediation did not resolve the alert; review the evidence and authorize remediation if appropriate.")
    end

    def enhancement_questions
      result(:enhancement_questions, :retry_enhancement,
        "Answer the preserved enhancement questions, or retry enhancement after reviewing them.")
    end

    def enhancement_failure
      result(:enhancement_failure, :retry_enhancement,
        "The prior enhancement run failed. Retrying enhancement will repeat its analysis.")
    end

    def unknown
      result(:unknown, :inspect,
        "Paid retained an unknown manual-review cause. Inspect the recorded reason before choosing work.")
    end

    def scanner_recurrence?
      Issues::CloseoutStatus.scanner_verification_blockers(issue).any? do |blocker|
        blocker.code == :scanner_verification_failed
      end
    end

    def enhancement_failure?
      issue.agent_runs.where(goal: "enhance_issue", status: "failed").exists?
    end

    def dependency_labels
      dependencies.map { |dependency| "##{dependency.github_number}" }.join(", ")
    end

    def result(cause, action, message, dependencies = [])
      Result.new(cause:, action:, message:, dependencies:)
    end
  end
end
