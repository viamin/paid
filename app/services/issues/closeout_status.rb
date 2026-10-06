# frozen_string_literal: true

module Issues
  # Explains whether an open issue is a stalled partial closeout and exactly
  # why automatic continuation cannot proceed, for the partial_closeout Inbox
  # lane and the continuation admission path (#4120).
  #
  # The status derives from {CloseoutEvidence} plus the same eligibility
  # guards auto-pick applies (`DefaultCandidateSource.eligible_scope` is the
  # admission authority), so the Inbox shows the *actual* blocker rather than
  # a parallel heuristic. Explicit operator states (paused flag, project
  # pause, skip labels, needs-input/manual-review, retry abandonment) are
  # deliberate holds with their own lanes — they surface as blockers, not as
  # stalls.
  # @spec PARTIAL-CLOSEOUT-002 @spec PARTIAL-CLOSEOUT-004
  class CloseoutStatus
    Blocker = Struct.new(:code, :message, keyword_init: true)

    # Blockers that are deliberate operator states or active work rather than
    # a partial-closeout stall; the lane must not surface them.
    NON_STALL_BLOCKER_CODES = %i[operator_pause run_in_flight].freeze

    Result = Struct.new(
      :evidence,
      :blockers,
      :admissible,
      :open_request,
      :resolved_current_generation,
      :outcome,
      :unresolved_prerequisites,
      keyword_init: true
    ) do
      def stalled?
        evidence.present? &&
          open_request.nil? &&
          !resolved_current_generation &&
          !admissible &&
          blockers.none? { |blocker| blocker.code.in?(NON_STALL_BLOCKER_CODES) }
      end

      def reason
        return "Paid has no terminal closeout evidence for this issue, so there is nothing to continue past." if evidence.blank?
        return "A deliberate continuation is already authorized and its run is in flight." if open_request.present?
        if resolved_current_generation
          return "Resolved complete against the current closeout evidence; newer terminal evidence would resurface it."
        end

        return blockers.map(&:message).join(" ") if blockers.any?

        if evidence.no_code_required_at.present?
          return "A prior agent-declared no-code-required outcome is terminal: automatic continuation would just " \
                 "re-declare it, so only a deliberate continuation can lift the guard once."
        end

        "The merged-PR duplicate-work guard (merged partial PR " \
          "#{evidence.merged_prs.map { |pr| "##{pr.number}" }.join(', ')}) keeps this issue out of auto-pick " \
          "regardless of paid_state; only a deliberate continuation can lift it once."
      end

      def blocker_codes
        blockers.map(&:code)
      end
    end

    def self.call(issue, eligible_issue_ids: nil, continuation_eligible_issue_ids: nil)
      evidence = CloseoutEvidence.call(issue)
      eligible_ids = eligible_issue_ids || admissible_issue_ids(issue)
      blockers = admission_blockers(issue)
      if blockers.empty? && evidence.present?
        blockers = [ residual_eligibility_blocker(issue, continuation_eligible_issue_ids) ].compact
      end

      Result.new(
        evidence: evidence,
        blockers: blockers,
        admissible: eligible_ids.include?(issue.id),
        open_request: IssueContinuationRequest.open_for_issue(issue),
        resolved_current_generation: issue.closeout_resolved? && issue.closeout_resolution_digest == evidence.digest,
        outcome: outcome_label(issue, evidence),
        unresolved_prerequisites: prerequisite_labels(issue)
      )
    end

    def self.admissible_issue_ids(issue)
      Automation::Strategies::AutoPick::DefaultCandidateSource
        .eligible_scope(issue.project).pluck(:id)
    end

    # Targeted walk over the guards that can hold an evidence-carrying issue
    # out of admission, producing user-facing reasons. Used by the Inbox
    # detail (the exact reason automatic continuation cannot proceed) and by
    # {RequestContinuation} refusal mapping. The authoritative admit/deny
    # decision remains `eligible_scope` with the scoped lift — this walk only
    # explains it.
    def self.admission_blockers(issue)
      prerequisite_blockers(issue) + operator_pause_blockers(issue) +
        run_in_flight_blockers(issue) + trust_blockers(issue) + feature_hold_blockers(issue) +
        analysis_backoff_blockers(issue)
    end

    # The walk above only explains the guards with clear per-issue reasons;
    # it can lag `eligible_scope` as new guards are added. This residual
    # preflight settles admission with the exact scoped decision the
    # dequeue-time recheck enforces (`eligible_for_dequeue?` carrying this
    # issue's continuation authorization), so {RequestContinuation} refuses
    # up front — with the reason — instead of queueing a run dequeue would
    # cancel and supersede, and the lane explains the real blocker instead
    # of the duplicate-work fallback (#4130 review).
    # @spec PARTIAL-CLOSEOUT-004
    def self.residual_eligibility_blocker(issue, continuation_eligible_issue_ids)
      admissible = if continuation_eligible_issue_ids
        continuation_eligible_issue_ids.include?(issue.id)
      else
        Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_for_dequeue?(
          issue.project,
          issue.id,
          excluding_run_id: nil,
          continuation_authorized_issue_ids: [ issue.id ]
        )
      end
      return nil if admissible

      Blocker.new(
        code: :ineligible,
        message: "Another auto-pick eligibility guard (for example open tracker references, " \
                 "an open linked pull request, an unresolved prerequisite notification, or a model " \
                 "tier no enabled runner can satisfy) still holds this issue out of scheduling; " \
                 "clear that guard before requesting a continuation."
      )
    end

    def self.prerequisite_blockers(issue)
      labels = prerequisite_labels(issue)
      return [] if labels.empty?

      [ Blocker.new(
        code: :unmet_prerequisites,
        message: "Unresolved prerequisite work (#{labels.join(', ')}) must be resolved or linked before continuation."
      ) ]
    end

    def self.operator_pause_blockers(issue)
      blockers = []
      if issue.paused? || issue.project.paused? || issue.project.quality_paused_at.present?
        blockers << Blocker.new(
          code: :operator_pause,
          message: "An explicit pause is active (the issue or its project is paused), and a continuation never bypasses it."
        )
      end
      if issue.paid_state.in?(%w[needs_input manual_review])
        blockers << Blocker.new(
          code: :operator_pause,
          message: "The issue is waiting for a human decision (#{issue.paid_state.tr('_', ' ')}); resolve that state first."
        )
      end
      if issue.runner_retry_abandoned_at.present?
        blockers << Blocker.new(
          code: :operator_pause,
          message: "The issue is retry-abandoned; clear the retry-cap flag from the retry-limited lane first."
        )
      end

      hit_labels = Array(issue.labels).select { |label| skip_label_set(issue).include?(label.to_s.downcase) }
      if hit_labels.any?
        blockers << Blocker.new(
          code: :operator_pause,
          message: "An auto-pick skip label (#{hit_labels.join(', ')}) deliberately holds this issue out of scheduling."
        )
      end
      blockers
    end

    def self.run_in_flight_blockers(issue)
      return [] unless issue.agent_runs.where(status: AgentRun::AUTO_PICK_BLOCKING_STATUSES).exists?

      [ Blocker.new(code: :run_in_flight, message: "An agent run is already queued or in flight for this issue.") ]
    end

    def self.trust_blockers(issue)
      trusted = issue.project.trusted_github_author_logins
      return [] if trusted.blank?
      return [] if trusted.map(&:downcase).include?(issue.github_creator_login.to_s.downcase)

      [ Blocker.new(
        code: :untrusted,
        message: "The issue creator (@#{issue.github_creator_login}) is not in the project's trusted allowlist."
      ) ]
    end

    def self.feature_hold_blockers(issue)
      admission = FeatureIntents::RunAdmission.call(issue: issue)
      return [] if admission.allowed?

      [ Blocker.new(code: :feature_held, message: admission.reason || "A feature release gate holds this issue.") ]
    end

    # Mirrors the `apply_issue_analysis_backoff` eligibility filter via the
    # canonical `Issue#issue_analysis_backoff_active?` predicate, so an
    # evidence-carrying issue cooling down after provider exhaustion refuses
    # continuation with the specific wait-until reason instead of queueing a
    # run the dequeue recheck would cancel.
    # @spec PARTIAL-CLOSEOUT-004
    def self.analysis_backoff_blockers(issue)
      next_attempt_at = issue.issue_analysis_next_attempt_at
      return [] if next_attempt_at.blank? || next_attempt_at <= Time.current

      reset_at = Issues::IssueAnalysisBackoffResetContext.call(project: issue.project)
      return [] unless issue.issue_analysis_backoff_active?(reset_at: reset_at)

      [ Blocker.new(
        code: :analysis_backoff,
        message: "Automatic issue analysis is in a provider-exhaustion backoff until " \
                 "#{next_attempt_at.utc.iso8601}; wait for the window to clear (or restore a " \
                 "capable runner to reset it) before requesting a continuation."
      ) ]
    end

    def self.prerequisite_labels(issue)
      local = (issue.blocking_issues.pluck(:github_number) +
        issue.blocking_deployment_dependencies.map { |dep| dep.depends_on_issue.github_number }).uniq.sort
      external = issue.blocking_external_dependencies.map do |dep|
        "#{dep.depends_on_owner}/#{dep.depends_on_repo}##{dep.depends_on_number}"
      end

      local.map { |number| "##{number}" } + external.sort
    end

    def self.outcome_label(issue, evidence)
      merged = evidence.merged_prs.map { |pr| "##{pr.number}" }.join(", ")
      parts = []
      parts << if evidence.no_code_required_at.present?
        "an agent declared no code required (#{evidence.no_code_required_at.utc.iso8601})"
      else
        "no no-code-required declaration"
      end
      parts << (merged.present? ? "merged partial PR #{merged}" : "no merged PR")
      "Paid recorded #{parts.join(' and ')}; paid_state is #{issue.paid_state}."
    end

    def self.skip_label_set(issue)
      Array(issue.project.effective_auto_pick_skip_labels).map(&:downcase).to_set
    end
  end
end
