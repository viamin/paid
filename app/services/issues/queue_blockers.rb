# frozen_string_literal: true

module Issues
  # Explains why an open issue is not eligible for automatic work, who owns
  # the block, and what the next supported action is (#4619).
  #
  # Read-only by construction. It never calls an LLM, never executes
  # repository code, and never mutates GitHub or the database, so it is safe
  # to evaluate while rendering a dashboard tile. The planning/feature hold
  # is read through the read-only {FeatureIntents::IssueHold} projection
  # rather than {FeatureIntents::RunAdmission}, which reconciles the hold and
  # would therefore mutate state during a render.
  #
  # Blockers are additive: simultaneous guards are all reported instead of
  # the first one concealing the rest.
  # @spec QUEUE-DIAG-003 @spec QUEUE-DIAG-007 @spec QUEUE-DIAG-009
  class QueueBlockers
    Blocker = Struct.new(:code, :message, :owner, :recovery, :evidence, keyword_init: true)

    # Resource and policy pauses rather than dependency or decision holds.
    # An issue whose blockers are all pauses is paused, not blocked.
    PAUSE_CODES = %i[project_paused issue_paused quality_paused scheduler_paused run_paused].freeze

    # Blockers a human must resolve. They route to the existing actionable
    # Inbox lane that already owns that decision.
    HUMAN_DECISION_CODES = %i[human_decision feature_hold].freeze

    Result = Struct.new(:issue, :blockers, keyword_init: true) do
      def blocked? = blockers.any?
      def paused? = blocked? && blockers.all? { |blocker| PAUSE_CODES.include?(blocker.code) }
      def human_decision? = blockers.any? { |blocker| HUMAN_DECISION_CODES.include?(blocker.code) }
      def codes = blockers.map(&:code)
      def owners = blockers.filter_map(&:owner).uniq
    end

    def self.call(issue, **options)
      new(issue:, **options).call
    end

    def initialize(issue:, closeout_evidence: nil, analysis_backoff_reset_at: nil)
      @issue = issue
      @closeout_evidence = closeout_evidence
      @analysis_backoff_reset_at = analysis_backoff_reset_at
    end

    def call
      Result.new(issue: issue, blockers: blockers)
    end

    private

    attr_reader :issue, :closeout_evidence, :analysis_backoff_reset_at

    def project = @project ||= issue.project

    def blockers
      @blockers ||= [
        prerequisite_blocker,
        sub_issue_blocker,
        human_decision_blocker,
        pause_blockers,
        skip_label_blocker,
        trust_blocker,
        feature_hold_blocker,
        analysis_backoff_blocker,
        scanner_blocker,
        merged_delivery_blocker,
        no_code_required_blocker,
        retry_abandoned_blocker,
        paused_run_blocker
      ].compact.flatten
    end

    # Unresolved dependency work owns the block: the dependent issue cannot
    # proceed until the named prerequisite is closed or linked.
    def prerequisite_blocker
      labels = prerequisite_labels
      return if labels.empty?

      Blocker.new(
        code: :unmet_prerequisites,
        message: "Unresolved prerequisite work (#{labels.join(', ')}) must be resolved or linked first.",
        owner: labels.join(", "),
        recovery: "Resolve the listed prerequisite work, or update its dependency link.",
        evidence: { "prerequisites" => labels }
      )
    end

    # A parent issue with open sub-issues is a coordination epic, not stalled
    # implementation work: the children own the progress.
    def sub_issue_blocker
      numbers = open_sub_issue_numbers
      return if numbers.empty?

      Blocker.new(
        code: :open_sub_issues,
        message: "Open sub-issues (#{numbers.join(', ')}) still own this issue's progress.",
        owner: numbers.join(", "),
        recovery: "Let the sub-issues progress, or close the ones that are no longer needed.",
        evidence: { "sub_issues" => numbers }
      )
    end

    # A human decision boundary. The recovery is the existing actionable
    # Inbox lane that owns the decision — never a new item.
    def human_decision_blocker
      state = issue.paid_state.to_s
      return unless state.in?(%w[needs_input manual_review])

      Blocker.new(
        code: :human_decision,
        message: "The issue is waiting for a human decision (#{state.tr('_', ' ')}).",
        owner: "operator",
        recovery: "Resolve the decision in the Inbox lane that owns it.",
        evidence: { "paid_state" => state }
      )
    end

    def pause_blockers
      blockers = []
      if project.paused?
        blockers << Blocker.new(
          code: :project_paused,
          message: "The project is paused, so no automatic work is admitted.",
          owner: "operator",
          recovery: "An authorized operator must resume the project."
        )
      end
      if project.quality_paused_at.present?
        blockers << Blocker.new(
          code: :quality_paused,
          message: "The project is quality-paused, so no automatic work is admitted.",
          owner: "quality gate",
          recovery: "Clear the quality pause (or let the quality recovery path act) before work resumes."
        )
      end
      if project.scheduler_paused_at.present? || project.account&.scheduler_paused?
        blockers << Blocker.new(
          code: :scheduler_paused,
          message: "The scheduler is paused for this project or account, so queued work is not dispatched.",
          owner: "scheduler policy",
          recovery: "Resume the scheduler for the project or account."
        )
      end
      if issue.paused?
        blockers << Blocker.new(
          code: :issue_paused,
          message: "The issue is explicitly paused.",
          owner: "operator",
          recovery: "An authorized operator must remove the issue pause."
        )
      end
      blockers
    end

    def skip_label_blocker
      labels = hit_skip_labels
      return if labels.empty?

      Blocker.new(
        code: :skip_label,
        message: "An auto-pick skip label (#{labels.join(', ')}) deliberately holds this issue out of scheduling.",
        owner: labels.join(", "),
        recovery: "Remove the skip label if new automated work is authorized.",
        evidence: { "labels" => labels }
      )
    end

    def trust_blocker
      trusted = project.trusted_github_author_logins.presence
      return if trusted.blank?
      return if trusted.map(&:downcase).include?(issue.github_creator_login.to_s.downcase)

      Blocker.new(
        code: :untrusted_author,
        message: "The issue creator (@#{issue.github_creator_login}) is not in the project's trusted allowlist.",
        owner: "project administrator",
        recovery: "An administrator must update the trusted-author policy.",
        evidence: { "creator" => issue.github_creator_login }
      )
    end

    # The read-only hold projection: it reports a recorded hold without
    # reconciling (and therefore without mutating) it.
    def feature_hold_blocker
      hold = FeatureIntents::IssueHold.call(issue: issue)
      return if hold.nil?

      Blocker.new(
        code: :feature_hold,
        message: hold.message,
        owner: "feature design",
        recovery: "Complete the feature release or design-revision gate before work resumes.",
        evidence: { "hold_code" => hold.code }
      )
    end

    def analysis_backoff_blocker
      next_attempt_at = issue.issue_analysis_next_attempt_at
      return if next_attempt_at.blank? || next_attempt_at <= Time.current
      return unless issue.issue_analysis_backoff_active?(reset_at: analysis_backoff_reset_at)

      Blocker.new(
        code: :analysis_backoff,
        message: "Automatic issue analysis is in a provider-exhaustion backoff until #{next_attempt_at.utc.iso8601}.",
        owner: "runner capacity",
        recovery: "Wait for the window to clear, or restore a capable runner.",
        evidence: { "next_attempt_at" => next_attempt_at.utc.iso8601 }
      )
    end

    def scanner_blocker
      return unless issue.source == Issue::SYNTHETIC_CODE_SCANNING_SOURCE

      attempt = issue.code_scanning_remediation_attempts.latest_per_issue.first
      return unless attempt&.status.in?(%w[awaiting_verification verification_failed verification_blocked])

      Blocker.new(
        code: :scanner_verification,
        message: "Code-scanning alert ##{issue.github_issue_id - Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET} " \
          "is still awaiting a verified outcome; a merge is not proof it is fixed.",
        owner: "code scanner",
        recovery: "Wait for the next matching scan, or explicitly authorize a new remediation.",
        evidence: { "attempt_status" => attempt.status, "attempt_id" => attempt.id }
      )
    end

    # A merged delivery is terminal evidence: the work was delivered, so the
    # issue is not eligible again unless a human authorizes a continuation.
    def merged_delivery_blocker
      merged = evidence&.merged_prs.to_a
      return if merged.empty?

      numbers = merged.map { |pr| "##{pr.number}" }
      Blocker.new(
        code: :merged_delivery,
        message: "A merged pull request (#{numbers.join(', ')}) is the terminal delivery for this issue.",
        owner: numbers.join(", "),
        recovery: "Review the delivered work; authorize a continuation only if scope remains.",
        evidence: { "merged_pull_requests" => numbers }
      )
    end

    def no_code_required_blocker
      return if evidence&.no_code_required_at.blank?

      Blocker.new(
        code: :no_code_required,
        message: "An agent declared the work complete without a code change, which is terminal.",
        owner: "agent declaration",
        recovery: "Authorize a new run explicitly if the issue still needs work.",
        evidence: { "no_code_required_at" => evidence.no_code_required_at.utc.iso8601 }
      )
    end

    def retry_abandoned_blocker
      return if issue.runner_retry_abandoned_at.blank?

      Blocker.new(
        code: :retry_abandoned,
        message: "The issue is retry-abandoned after every available provider hit the per-issue retry cap.",
        owner: "operator",
        recovery: "Clear the retry-cap flag from the retry-limited lane first.",
        evidence: { "abandoned_at" => issue.runner_retry_abandoned_at.utc.iso8601 }
      )
    end

    # A paused run is a resource pause, not a dependency or decision hold.
    def paused_run_blocker
      return unless issue.agent_runs.where(status: "paused").exists?

      Blocker.new(
        code: :run_paused,
        message: "A paused agent run still covers this issue, so no new run is admitted.",
        owner: "operator",
        recovery: "Resume or cancel the paused run.",
        evidence: {}
      )
    end

    def evidence
      return @evidence if defined?(@evidence)

      @evidence = closeout_evidence || Issues::CloseoutEvidence.call(issue)
    end

    def prerequisite_labels
      @prerequisite_labels ||= Issues::CloseoutStatus.prerequisite_labels(issue)
    end

    def open_sub_issue_numbers
      @open_sub_issue_numbers ||= issue.sub_issues
        .where(github_state: "open", is_pull_request: false)
        .where.not(paid_state: Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES)
        .pluck(:github_number)
    end

    def hit_skip_labels
      @hit_skip_labels ||= begin
        skip = project.effective_auto_pick_skip_labels.map(&:downcase)
        return [] if skip.empty?

        Array(issue.labels).select { |label| skip.include?(label.to_s.downcase) }
      end
    end
  end
end
