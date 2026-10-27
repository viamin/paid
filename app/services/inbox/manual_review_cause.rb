# frozen_string_literal: true

module Inbox
  # Classifies why an issue is parked in `manual_review` and names the
  # supported recovery for that cause (#4640).
  #
  # Every cause is read from explicit provenance — the reopen-review reason,
  # the dependency-blocked parking reason, the recorded scanner verification
  # attempt, and the enhancement stop evidence. A cause that cannot be
  # resolved stays visible as `unknown` instead of being folded into the
  # enhancement lane.
  #
  # @spec MANUAL-REVIEW-RECOVERY-001
  class ManualReviewCause
    REOPEN_REVIEW = "reopen_review"
    DEPENDENCY_WAIT = "dependency_wait"
    SCANNER_RECURRENCE = "scanner_recurrence"
    ENHANCEMENT = "enhancement"
    UNKNOWN = "unknown"

    CAUSES = [ REOPEN_REVIEW, DEPENDENCY_WAIT, SCANNER_RECURRENCE, ENHANCEMENT, UNKNOWN ].freeze

    LABELS = {
      REOPEN_REVIEW => "Reopened after closure",
      DEPENDENCY_WAIT => "Waiting on a dependency",
      SCANNER_RECURRENCE => "Scanner-confirmed recurrence",
      ENHANCEMENT => "Enhancement stopped",
      UNKNOWN => "Unclassified manual review"
    }.freeze

    # What an offered action does, so an operator can tell a recorded
    # decision from a retried analysis, a resumed implementation and a
    # collected evidence request.
    RECORDS_DECISION = "records_decision"
    RETRIES_ANALYSIS = "retries_analysis"
    RESUMES_IMPLEMENTATION = "resumes_implementation"
    COLLECTS_EVIDENCE = "collects_evidence"

    SEMANTICS = {
      RECORDS_DECISION => "Records a decision",
      RETRIES_ANALYSIS => "Retries analysis",
      RESUMES_IMPLEMENTATION => "Resumes implementation",
      COLLECTS_EVIDENCE => "Collects evidence"
    }.freeze

    RECORD_INTENT_VALIDATION = "record_intent_validation"
    RETRY_ANALYSIS = "retry_analysis"
    RESUME_IMPLEMENTATION = "resume_implementation"
    RESOLVE_DEPENDENCY = "resolve_dependency"

    # The enhancement stop reasons Paid itself writes. A parser, transport
    # or round-limit failure is an enhancement cause: the supported recovery
    # is a new enhancement attempt, not a different workflow.
    ENHANCEMENT_REASON_MARKERS = /enhance|round limit|re-evaluation round|structured output|clarifying question/i

    Hold = Struct.new(:code, :message, :recovery, :links, keyword_init: true)
    Action = Struct.new(:kind, :label, :semantics, :description, :goal, keyword_init: true)
    Scope = Struct.new(:closed_at, :closure, :remaining, keyword_init: true)
    Result = Struct.new(:code, :label, :summary, :holds, :actions, :scope, :revision, keyword_init: true) do
      def unknown? = code == UNKNOWN
      def reopen_review? = code == REOPEN_REVIEW
      def dependency_wait? = code == DEPENDENCY_WAIT
      def scanner_recurrence? = code == SCANNER_RECURRENCE
      def enhancement? = code == ENHANCEMENT
      def hold_codes = holds.map(&:code)
      def action_kinds = actions.map(&:kind)
      def semantics_labels = actions.map { |action| SEMANTICS.fetch(action.semantics, action.semantics) }
    end

    def self.call(issue:, questions: [])
      new(issue:, questions:).call
    end

    def initialize(issue:, questions: [])
      @issue = issue
      @questions = Array(questions)
    end

    def call
      Result.new(
        code: cause_code,
        label: LABELS.fetch(cause_code),
        summary: summary,
        holds: holds,
        actions: actions,
        scope: scope,
        revision: revision
      )
    end

    private

    attr_reader :issue, :questions

    # The classification order keeps the most specific recorded provenance
    # first: an explicit reopen gate, a recorded scanner recurrence, an
    # explicit dependency-blocked parking reason, then enhancement evidence.
    def cause_code
      return REOPEN_REVIEW if reopen_review_parked?
      return SCANNER_RECURRENCE if scanner_recurrence?
      return DEPENDENCY_WAIT if dependency_blocked_reason?
      return ENHANCEMENT if enhancement_stopped?
      return DEPENDENCY_WAIT if unresolved_dependency?

      UNKNOWN
    end

    def reopen_review_parked?
      issue.manual_review_reason == Issue::REOPEN_REVIEW_REQUIRED_REASON
    end

    def scanner_recurrence?
      scanner_blockers.any?
    end

    # The dependency-blocked parking reason is written by Paid itself
    # (FetchIssuesActivity#dependency_blocked_reason), so its marker is
    # explicit provenance rather than an inference from arbitrary text.
    def dependency_blocked_reason?
      issue.manual_review_reason.to_s.include?(Issue::DEPENDENCY_BLOCKED_REASON_MARKER)
    end

    def enhancement_stopped?
      enhancement_reason? || enhancement_questions? || enhancement_run_evidence?
    end

    # The stop reason Paid itself wrote for an enhancement round.
    def enhancement_reason?
      issue.manual_review_reason.to_s.match?(ENHANCEMENT_REASON_MARKERS)
    end

    def enhancement_questions?
      issue.needs_input_questions.present?
    end

    # The last run on the issue was an enhancement run: weaker evidence than
    # a recorded stop reason, used only when nothing else explains the stop.
    def enhancement_run_evidence?
      latest_run&.enhance_issue_goal? || false
    end

    def unresolved_dependency?
      dependency_labels.any?
    end

    def holds
      [ reopen_hold, dependency_hold, scanner_hold, enhancement_hold, in_flight_hold ].compact
    end

    def reopen_hold
      return unless reopen_review_parked?

      Hold.new(
        code: REOPEN_REVIEW,
        message: "This issue was reopened after closure, so its current intent must be validated before work resumes.",
        recovery: "Record the intent-validation decision, then start the supported continuation."
      )
    end

    def dependency_hold
      return unless dependency_labels.any? || dependency_blocked_reason?

      Hold.new(
        code: DEPENDENCY_WAIT,
        message: dependency_message,
        recovery: "Resolve the listed prerequisite work; Paid re-evaluates this issue when it resolves.",
        links: dependency_links
      )
    end

    # The dependency edges name the blockers when they are still recorded.
    # The parking reason names them when the edges are gone, so the operator
    # still sees what the issue is waiting for.
    def dependency_message
      return issue.manual_review_reason if dependency_labels.empty?

      "Unresolved prerequisite work (#{dependency_labels.join(', ')}) blocks this issue."
    end

    def scanner_hold
      blocker = scanner_blockers.first
      return unless blocker

      Hold.new(
        code: SCANNER_RECURRENCE,
        message: blocker.message,
        recovery: blocker.recovery,
        links: scanner_links(blocker)
      )
    end

    def enhancement_hold
      return unless enhancement_stopped?

      Hold.new(
        code: ENHANCEMENT,
        message: enhancement_message,
        recovery: "Answer the preserved clarifying questions, or retry the issue analysis."
      )
    end

    def enhancement_message
      return issue.manual_review_reason if enhancement_reason?
      return "Paid stopped enhancing this issue and preserved its clarifying questions." if enhancement_questions?

      "Paid stopped this issue after an issue-enhancement run that produced no usable verdict."
    end

    # Work that is already queued or running is inspected before any resume:
    # a second run would compete with it, and the hold must not be cleared
    # while an incompatible run is still queued.
    def in_flight_hold
      run = in_flight_runs.first
      return unless run

      Hold.new(
        code: "run_in_flight",
        message: "Run ##{run.id} (#{run.goal}) is already #{run.status} for this issue.",
        recovery: "Reuse that run, or reconcile it before starting another one."
      )
    end

    def actions
      case cause_code
      when REOPEN_REVIEW then reopen_actions
      when DEPENDENCY_WAIT then [ dependency_action ]
      when SCANNER_RECURRENCE then [ remediation_action ]
      when ENHANCEMENT then [ retry_analysis_action ]
      else [ unknown_action ]
      end
    end

    def reopen_actions
      return [ intent_validation_action ] unless validated?

      case issue.reopen_review_decision
      when Issues::ResolveReopenReview::SUPERSEDED then []
      else [ retry_analysis_action, implementation_action ]
      end
    end

    # A decision made against a scope that has since changed describes work
    # that is no longer the recorded scope: it asks for a fresh validation
    # instead of a continuation.
    def validated?
      issue.reopen_review_decided? && !issue.reopen_review_stale?
    end

    def intent_validation_action
      Action.new(
        kind: RECORD_INTENT_VALIDATION,
        label: "Record intent validation",
        semantics: RECORDS_DECISION,
        description: "Validate whether the original intent still applies. The decision is bound to the scope you are reviewing."
      )
    end

    def retry_analysis_action
      Action.new(
        kind: RETRY_ANALYSIS,
        label: "Start enhancement run",
        semantics: RETRIES_ANALYSIS,
        description: "Starts a new enhancement round so Paid can re-read the issue and its context.",
        goal: "enhance_issue"
      )
    end

    def implementation_action
      Action.new(
        kind: RESUME_IMPLEMENTATION,
        label: "Start implementation run",
        semantics: RESUMES_IMPLEMENTATION,
        description: "Starts an implementation run for the validated scope.",
        goal: "create_pr"
      )
    end

    def remediation_action
      Action.new(
        kind: RESUME_IMPLEMENTATION,
        label: "Authorize new remediation",
        semantics: RESUMES_IMPLEMENTATION,
        description: "Starts a remediation run for the finding the scanner confirmed is still open.",
        goal: "create_pr"
      )
    end

    def dependency_action
      Action.new(
        kind: RESOLVE_DEPENDENCY,
        label: "Open the blocking work",
        semantics: COLLECTS_EVIDENCE,
        description: "The blocking owner completes the prerequisite work; Paid re-evaluates this issue when it resolves."
      )
    end

    def unknown_action
      Action.new(
        kind: RETRY_ANALYSIS,
        label: "Start enhancement run",
        semantics: RETRIES_ANALYSIS,
        description: "The cause could not be classified from the recorded evidence. This retry re-runs the issue analysis."
      )
    end

    def summary
      case cause_code
      when REOPEN_REVIEW then "Paid stopped this issue because it was reopened after closure; its intent must be validated first."
      when DEPENDENCY_WAIT then "Paid stopped this issue because it is blocked on unresolved dependency work."
      when SCANNER_RECURRENCE then "Paid stopped this issue because a scanner-confirmed recurrence needs an explicit remediation decision."
      when ENHANCEMENT then "Paid stopped enhancing this issue: #{enhancement_message}."
      else "Paid stopped this issue for a reason that could not be classified from the recorded evidence."
      end
    end

    # The closure the operator is reviewing, and the scope that remains.
    def scope
      return unless reopen_review_parked?

      Scope.new(closed_at: issue.closed_at, closure: closure_summary, remaining: remaining_scope)
    end

    def closure_summary
      if issue.closeout_resolved_at.present?
        "An operator resolved this issue as complete against the recorded closeout evidence " \
          "on #{issue.closeout_resolved_at.utc.iso8601}."
      elsif issue.partial_completion_reason.present?
        "The last recorded outcome was a partial completion: #{issue.partial_completion_reason}"
      elsif issue.closed_at.present?
        "The issue was closed on GitHub on #{issue.closed_at.utc.iso8601} without a recorded closeout resolution."
      else
        "The issue was closed on GitHub before Paid recorded a closeout outcome."
      end
    end

    def remaining_scope
      missing = Array(issue.last_analyzer_missing_context_areas).presence
      scope = issue.body.to_s.strip
      return issue.title if scope.blank? && missing.blank?

      parts = [ scope.presence ? scope.truncate(600) : issue.title ]
      parts << "Still missing context: #{missing.join(', ')}" if missing
      parts.join("\n\n")
    end

    def revision
      Issue.reopen_review_revision_for(title: issue.title, body: issue.body)
    end

    def scanner_blockers
      @scanner_blockers ||= Issues::CloseoutStatus.scanner_verification_blockers(issue)
    end

    def scanner_links(blocker)
      links = Array(blocker.evidence["links"]).map { |link| { "label" => link["label"], "url" => link["url"] } }
      url = blocker.evidence["attempt_url"]
      links.unshift({ "label" => "Scanner evidence", "url" => url }) if url.present?
      links
    end

    def dependency_labels
      @dependency_labels ||= Issues::CloseoutStatus.prerequisite_labels(issue)
    end

    def dependency_links
      local = issue.blocking_issues.map { |blocking| { "label" => "##{blocking.github_number}", "url" => blocking.github_url } }
      external = issue.blocking_external_dependencies.map do |dependency|
        { "label" => dependency.external_ref, "url" => "https://github.com/#{dependency.external_ref.sub('#', '/issues/')}" }
      end
      local + external
    end

    def latest_run
      @latest_run ||= issue.agent_runs.order(created_at: :desc, id: :desc).first
    end

    def in_flight_runs
      @in_flight_runs ||= issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(created_at: :asc, id: :asc).to_a
    end
  end
end
