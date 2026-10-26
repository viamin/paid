# frozen_string_literal: true

module Issues
  # Classifies a manual-review hold only from durable producer evidence. It
  # deliberately does not infer a cause from human-readable reason text.
  # @spec OPERATOR-INBOX-002K
  class ManualReviewRecovery
    Result = Data.define(:cause, :issue, :active_run) do
      def enhancement?
        cause == :enhancement
      end

      def reopen_review?
        cause == :reopen_review
      end

      def dependency_wait?
        cause == :dependency_wait
      end

      def scanner_recurrence?
        cause == :scanner_recurrence
      end

      def unknown?
        cause == :unknown
      end

      def action
        return :reuse_active_run if active_run
        return :record_reopen_validation if reopen_review? && !issue.reopen_review_validated_for_current_revision?
        return :resume_implementation if reopen_review? || scanner_recurrence?
        return :wait_for_dependency if dependency_wait?
        return :retry_enhancement if enhancement?

        :investigate
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(issue:)
      @issue = issue
    end

    def call
      Result.new(cause:, issue:, active_run: active_run)
    end

    private

    attr_reader :issue

    def cause
      return :reopen_review if issue.reopen_review_pending?
      return :dependency_wait if issue.blocking_issues.exists? || issue.blocking_deployment_dependencies.exists? || issue.blocking_external_dependencies.exists?
      return :scanner_recurrence if issue.code_scanning_remediation_attempts.where(status: "verification_failed").exists?
      return :enhancement if issue.needs_input_questions.present?
      return :enhancement if issue.agent_runs.where(goal: "enhance_issue").exists?
      # Before cause-specific recovery, the only producer of a populated
      # manual-review reason was the enhancement stop service. Preserve that
      # durable producer contract for legacy holds; a blank reason stays
      # unknown instead of inventing an action.
      return :enhancement if issue.manual_review_reason.present?

      :unknown
    end

    def active_run
      issue.agent_runs.where(status: AgentRun::DEDUP_BLOCKING_STATUSES).order(created_at: :asc, id: :asc).first
    end
  end
end
