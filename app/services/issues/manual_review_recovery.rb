# frozen_string_literal: true

module Issues
  # Classifies an Inbox manual-review hold from durable producer evidence. The
  # Inbox must not infer a recovery from prose: an unknown hold stays visible
  # and non-resumable until its producer supplies an explicit path.
  # @spec OPERATOR-INBOX-002L @spec ISSUE-REOPEN-REVIEW-005
  class ManualReviewRecovery
    Recovery = Data.define(:cause, :label, :instruction, :active_run, :dependency_numbers) do
      def resumable?
        active_run.nil? && cause.in?(%i[enhancement_failure enhancement_questions])
      end
    end

    CAUSES = {
      reopen_review: [ "Reopen review required", "Validate the prior closure and choose evidence collection or implementation." ],
      dependency_wait: [ "Waiting on a dependency", "The dependency must resolve before this issue can resume." ],
      scanner_recurrence: [ "Scanner-confirmed recurrence", "Review scanner evidence and explicitly authorize remediation if appropriate." ],
      enhancement_questions: [ "Enhancement questions require answers", "Answer the preserved questions or retry enhancement." ],
      enhancement_failure: [ "Enhancement recovery", "Retry the interrupted enhancement analysis." ],
      unknown: [ "Unknown manual-review cause", "This hold has no recognized producer provenance. Inspect the reason before changing it." ]
    }.freeze

    def self.call(...) = new(...).call

    def initialize(issue)
      @issue = issue
    end

    def call
      cause = classified_cause
      label, instruction = CAUSES.fetch(cause)
      Recovery.new(cause:, label:, instruction:, active_run:, dependency_numbers:)
    end

    private

    attr_reader :issue

    def classified_cause
      return :reopen_review if issue.reopen_review_pending?
      return :dependency_wait if dependency_numbers.any?
      return :scanner_recurrence if scanner_recurrence?
      return :enhancement_questions if issue.needs_input_questions.present?
      return :enhancement_failure if latest_run&.enhance_issue_goal? || enhancement_provenance?

      :unknown
    end

    def active_run
      @active_run ||= issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(created_at: :desc, id: :desc).first
    end

    def latest_run
      @latest_run ||= issue.agent_runs.order(created_at: :desc, id: :desc).first
    end

    def dependency_numbers
      @dependency_numbers ||= issue.blocking_issues.pluck(:github_number).sort
    end

    def scanner_recurrence?
      Issues::CloseoutStatus.scanner_verification_blockers(issue).any? { |blocker| blocker.code == :scanner_verification_failed }
    end

    # These are producer-owned, stable stop messages, not a semantic reading
    # of arbitrary operator prose. Older holds have no typed provenance, so a
    # message outside this explicit set remains unknown.
    def enhancement_provenance?
      issue.manual_review_reason.to_s.match?(
        /enhancement re-evaluation|round limit reached|Structured output (was invalid|failed validation)|could not validate the enhancement|Enhancement transport failed/i
      )
    end
  end
end
