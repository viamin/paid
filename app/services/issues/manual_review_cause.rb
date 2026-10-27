# frozen_string_literal: true

module Issues
  # Explains why an issue is parked in `manual_review` and which recovery the
  # operator Inbox must offer for that cause (#4640).
  #
  # Classification reads explicit provenance only: the dedicated reopen-review
  # reason, the enhancement stop paths and the clarifying questions they
  # preserve, unresolved dependency edges, scanner remediation evidence, and
  # the recorded partial-completion assessment. A cause that cannot be
  # established stays `unknown` and keeps the issue visible — the lane never
  # infers a cause from the prose of a free-text reason.
  #
  # Every applicable cause is returned, not only the first one, so simultaneous
  # holds (a reopened issue that is also blocked on a dependency) stay visible
  # instead of one hold concealing the other.
  #
  # @spec MANUAL-REVIEW-RECOVERY-001
  class ManualReviewCause
    REOPEN_REVIEW = "reopen_review"
    ENHANCEMENT = "enhancement"
    DEPENDENCY_WAIT = "dependency_wait"
    SCANNER_RECURRENCE = "scanner_recurrence"
    PARTIAL_CLOSEOUT = "partial_closeout"
    UNKNOWN = "unknown"

    # Priority order: the first matching cause owns the offered recovery; the
    # remaining ones are rendered as simultaneous holds.
    CAUSES = [
      REOPEN_REVIEW,
      SCANNER_RECURRENCE,
      PARTIAL_CLOSEOUT,
      ENHANCEMENT,
      DEPENDENCY_WAIT,
      UNKNOWN
    ].freeze

    # What the offered action does to the issue's work. The pane states this
    # next to every action so the operator knows whether they are recording a
    # decision, retrying analysis, or resuming implementation.
    RECORDS_DECISION = "records a decision"
    RETRIES_ANALYSIS = "retries analysis"
    RESUMES_IMPLEMENTATION = "resumes implementation"

    # @spec MANUAL-REVIEW-RECOVERY-007
    Action = Struct.new(:kind, :label, :effect, keyword_init: true) do
      def records_decision? = effect == RECORDS_DECISION
    end

    # A blocker the operator owns elsewhere: the reference, the repository
    # that owns it, and the action that resolves it.
    Dependency = Struct.new(:kind, :reference, :url, :owner, :action, keyword_init: true)

    Cause = Struct.new(:kind, :summary, :evidence, :action, keyword_init: true) do
      def effect = action&.effect
    end

    Classification = Struct.new(:causes, :reason, keyword_init: true) do
      def primary = causes.first
      def include?(kind) = causes.any? { |cause| cause.kind == kind }
      def reopen_review? = include?(REOPEN_REVIEW)
      def enhancement? = include?(ENHANCEMENT)
      def dependency_wait? = include?(DEPENDENCY_WAIT)
      def scanner_recurrence? = include?(SCANNER_RECURRENCE)
      def partial_closeout? = include?(PARTIAL_CLOSEOUT)
      def unknown? = include?(UNKNOWN)
      def simultaneous = causes.drop(1)
    end

    def self.call(issue)
      new(issue).call
    end

    def initialize(issue)
      @issue = issue
    end

    def call
      causes = []
      causes << reopen_review_cause if reopen_review?
      causes << scanner_cause if scanner_recurrence?
      causes << partial_closeout_cause if partial_closeout?
      causes << enhancement_cause if enhancement?
      causes << dependency_cause if dependency_wait?
      causes << unknown_cause if causes.empty?

      Classification.new(causes: causes, reason: issue.manual_review_reason)
    end

    # The unresolved dependencies behind a dependency wait, each with the
    # repository that owns it and the action that resolves it.
    # @spec MANUAL-REVIEW-RECOVERY-003
    def self.dependencies_for(issue)
      local = issue.blocking_issues.to_a.map do |blocker|
        Dependency.new(
          kind: "local",
          reference: "##{blocker.github_number}",
          url: blocker.github_url,
          owner: blocker.project.full_name,
          action: "Resolve ##{blocker.github_number} in #{blocker.project.full_name}."
        )
      end

      deployment = issue.blocking_deployment_dependencies.to_a.map do |dependency|
        target = dependency.depends_on_issue
        Dependency.new(
          kind: "deployment",
          reference: "##{target.github_number}",
          url: target.github_url,
          owner: target.project.full_name,
          action: "Deploy the merged PR ##{target.github_number} in #{target.project.full_name}."
        )
      end

      external = issue.blocking_external_dependencies.to_a.map do |dependency|
        reference = "#{dependency.depends_on_owner}/#{dependency.depends_on_repo}##{dependency.depends_on_number}"
        Dependency.new(
          kind: "external",
          reference: reference,
          url: nil,
          owner: "#{dependency.depends_on_owner}/#{dependency.depends_on_repo}",
          action: "Resolve #{reference} in #{dependency.depends_on_owner}/#{dependency.depends_on_repo}."
        )
      end

      (local + deployment + external).sort_by(&:reference)
    end

    private

    attr_reader :issue

    # The recorded cause is authoritative when the producer wrote one; rows
    # parked before the column existed fall back to the provenance that is
    # still on the issue.
    def recorded_cause
      cause = issue.manual_review_cause.to_s
      CAUSES.include?(cause) ? cause : nil
    end

    def reopen_review?
      recorded_cause == REOPEN_REVIEW || issue.reopen_review_pending?
    end

    def scanner_recurrence?
      recorded_cause == SCANNER_RECURRENCE || !scanner_blockers.empty?
    end

    def partial_closeout?
      recorded_cause == PARTIAL_CLOSEOUT || issue.partial_completion_at.present?
    end

    def enhancement?
      recorded_cause == ENHANCEMENT || enhancement_provenance?
    end

    def dependency_wait?
      recorded_cause == DEPENDENCY_WAIT || !dependencies.empty?
    end

    def enhancement_provenance?
      return true if issue.needs_input_questions.present?

      latest_run&.enhance_issue_goal?
    end

    def latest_run
      @latest_run ||= issue.agent_runs.order(created_at: :desc, id: :desc).first
    end

    def dependencies
      @dependencies ||= self.class.dependencies_for(issue)
    end

    def scanner_blockers
      @scanner_blockers ||= Issues::CloseoutStatus.scanner_verification_blockers(issue)
    end

    def reopen_review_cause
      Cause.new(
        kind: REOPEN_REVIEW,
        summary: "The issue was reopened after Paid closed it. Validate the original closure and " \
                 "the remaining scope before it can be completed again.",
        evidence: {
          "closure" => closure_evidence,
          "remaining_scope" => remaining_scope_evidence
        },
        action: Action.new(
          kind: "record_intent_validation",
          label: "Record intent validation",
          effect: RECORDS_DECISION
        )
      )
    end

    def scanner_cause
      Cause.new(
        kind: SCANNER_RECURRENCE,
        summary: "A merged remediation was re-scanned and the finding is still open, so the fix " \
                 "is not proven. Review the failed verification and authorize a new remediation.",
        evidence: {
          "blockers" => scanner_blockers.map do |blocker|
            {
              "code" => blocker.code.to_s,
              "message" => blocker.message,
              "recovery" => blocker.recovery,
              "evidence" => blocker.evidence
            }
          end
        },
        action: Action.new(
          kind: "authorize_scanner_remediation",
          label: "Authorize new remediation",
          effect: RESUMES_IMPLEMENTATION
        )
      )
    end

    def partial_closeout_cause
      Cause.new(
        kind: PARTIAL_CLOSEOUT,
        summary: "Paid's completion assessment found the merged implementation incomplete, so the " \
                 "remaining work needs a deliberate continuation.",
        evidence: {
          "reason" => issue.partial_completion_reason,
          "pull_request_number" => issue.partial_completion_pr_number,
          "assessed_at" => issue.partial_completion_at&.utc&.iso8601
        },
        action: Action.new(
          kind: "request_continuation",
          label: "Request continuation",
          effect: RESUMES_IMPLEMENTATION
        )
      )
    end

    def enhancement_cause
      Cause.new(
        kind: ENHANCEMENT,
        summary: "Paid stopped enhancing this issue and needs a human answer or a fresh analysis.",
        evidence: {
          "questions" => Array(issue.needs_input_questions),
          "enhance_issue_rounds" => issue.enhance_issue_rounds,
          "last_analyzer_sufficient_context" => issue.last_analyzer_sufficient_context,
          "last_analyzer_reasoning" => issue.last_analyzer_reasoning
        },
        action: enhancement_action
      )
    end

    # Preserved questions are the answerable surface of an enhancement stop:
    # the answer form stays the primary action, and the retry stays available.
    # A stop with no preserved questions (a parse failure, a transport
    # failure, the round limit) has nothing to answer, so the retry of the
    # analysis is the only supported action.
    def enhancement_action
      if issue.needs_input_questions.present?
        Action.new(
          kind: "submit_answers",
          label: "Answer the clarifying questions",
          effect: RECORDS_DECISION
        )
      else
        Action.new(
          kind: "retry_enhancement",
          label: "Retry enhancement analysis",
          effect: RETRIES_ANALYSIS
        )
      end
    end

    def dependency_cause
      Cause.new(
        kind: DEPENDENCY_WAIT,
        summary: "This issue is blocked on unresolved dependency work. The dependency has to " \
                 "resolve before the issue can continue.",
        evidence: {
          "dependencies" => dependencies.map do |dependency|
            {
              "kind" => dependency.kind,
              "reference" => dependency.reference,
              "url" => dependency.url,
              "owner" => dependency.owner,
              "action" => dependency.action
            }
          end
        },
        action: Action.new(
          kind: "reevaluate_dependency",
          label: "Re-evaluate dependency",
          effect: RETRIES_ANALYSIS
        )
      )
    end

    def unknown_cause
      Cause.new(
        kind: UNKNOWN,
        summary: "Paid stopped working this issue for a reason it cannot classify. The recorded " \
                 "reason is shown below; review it before resuming work.",
        evidence: { "reason" => issue.manual_review_reason },
        action: Action.new(
          kind: "retry_enhancement",
          label: "Retry enhancement analysis",
          effect: RETRIES_ANALYSIS
        )
      )
    end

    def closure_evidence
      evidence = Issues::CloseoutEvidence.call(issue)
      {
        "closed_at" => issue.closed_at&.utc&.iso8601,
        "reopened_at" => issue.reopened_at&.utc&.iso8601,
        "reopen_reason" => issue.reopen_reason,
        "merged_prs" => evidence.merged_prs.map { |pr| { "number" => pr.number, "url" => pr.url } },
        "no_code_required_at" => evidence.no_code_required_at&.utc&.iso8601
      }
    end

    def remaining_scope_evidence
      {
        "title" => issue.title,
        "body" => issue.body.to_s.truncate(500),
        "questions" => Array(issue.needs_input_questions),
        "last_analyzer_sufficient_context" => issue.last_analyzer_sufficient_context,
        "last_analyzer_reasoning" => issue.last_analyzer_reasoning
      }
    end
  end
end
