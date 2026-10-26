# frozen_string_literal: true

module Issues
  # Explains whether an open issue is a stalled partial closeout and exactly
  # why automatic continuation cannot proceed, for the partial_closeout Inbox
  # lane and the continuation admission path (#4120).
  #
  # The status derives from {CloseoutEvidence} plus the same eligibility
  # guards auto-pick applies (`DefaultCandidateSource.eligible_scope` is the
  # admission authority). Diagnostics name evidence from the guard which
  # denied admission; an unknown denial is deliberately marked unavailable,
  # never guessed. Explicit operator states (paused flag, project
  # pause, skip labels, needs-input/manual-review, retry abandonment) are
  # deliberate holds with their own lanes — they surface as blockers, not as
  # stalls.
  # @spec PARTIAL-CLOSEOUT-002 @spec PARTIAL-CLOSEOUT-004 @spec PARTIAL-CLOSEOUT-012
  class CloseoutStatus
    Blocker = Struct.new(:code, :message, :evidence, :recovery, keyword_init: true)
    Inputs = Struct.new(:evidence_by_issue_id, :prerequisites_by_issue_id,
      :open_requests_by_issue_id, :active_run_issue_ids, :feature_links_by_issue_id,
      :analysis_backoff_reset_by_project_id, :scanner_attempts_by_issue_id,
      :native_children_by_issue_id, :prerequisite_notifications_by_issue_id, keyword_init: true)

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

    def self.call(issue, eligible_issue_ids: nil, continuation_eligible_issue_ids: nil, inputs: nil)
      evidence = inputs&.evidence_by_issue_id&.fetch(issue.id) || CloseoutEvidence.call(issue)
      eligible_ids = eligible_issue_ids || admissible_issue_ids(issue)
      prerequisites = inputs&.prerequisites_by_issue_id&.fetch(issue.id) || prerequisite_labels(issue)
      blockers = admission_blockers(issue, prerequisites: prerequisites, inputs: inputs)
      if blockers.empty? && evidence.present?
        blockers = [ residual_eligibility_blocker(issue, continuation_eligible_issue_ids) ].compact
      end

      Result.new(
        evidence: evidence,
        blockers: blockers,
        admissible: eligible_ids.include?(issue.id),
        open_request: inputs ? inputs.open_requests_by_issue_id[issue.id] : IssueContinuationRequest.open_for_issue(issue),
        resolved_current_generation: issue.closeout_resolved? && issue.closeout_resolution_digest == evidence.digest,
        outcome: outcome_label(issue, evidence),
        unresolved_prerequisites: prerequisites
      )
    end

    # Preloads the mutable persisted inputs used only to explain each
    # candidate's admission result. The eligibility authority remains the
    # scoped batch evaluation in StalledCloseouts.
    # @spec PARTIAL-CLOSEOUT-026
    def self.inputs_for(issues)
      return Inputs.new if issues.empty?

      issue_ids = issues.map(&:id)
      feature_links = FeatureIntentIssue.where(issue_id: issue_ids).includes(:feature_intent, :prerequisite_mapping,
        in_tree_dependencies: :issue).order(:id).to_a.group_by(&:issue_id)
      scanner_attempts = CodeScanningRemediationAttempt.where(issue_id: issue_ids).latest_per_issue.index_by(&:issue_id)
      native_children = open_native_children_for(issues)
      prerequisite_notifications = active_prerequisite_notifications_for(issues)
      reset_at = issues.group_by(&:project_id).transform_values do |project_issues|
        next unless project_issues.any? { |issue| issue.issue_analysis_next_attempt_at.present? && issue.issue_analysis_next_attempt_at > Time.current }

        IssueAnalysisBackoffResetContext.call(project: project_issues.first.project)
      end
      Inputs.new(
        evidence_by_issue_id: CloseoutEvidence.results_for(issues),
        prerequisites_by_issue_id: prerequisite_labels_for(issues),
        open_requests_by_issue_id: IssueContinuationRequest.open.where(issue_id: issue_ids).order(:id).to_a.index_by(&:issue_id),
        active_run_issue_ids: AgentRun.where(issue_id: issue_ids, status: AgentRun::AUTO_PICK_BLOCKING_STATUSES).distinct.pluck(:issue_id).to_set,
        feature_links_by_issue_id: feature_links,
        analysis_backoff_reset_by_project_id: reset_at,
        scanner_attempts_by_issue_id: scanner_attempts,
        native_children_by_issue_id: native_children,
        prerequisite_notifications_by_issue_id: prerequisite_notifications
      )
    end

    def self.prerequisite_labels_for(issues)
      labels = Hash.new { |hash, key| hash[key] = [] }
      issue_ids = issues.map(&:id)
      dependencies = IssueDependency.joins(<<~SQL.squish)
        INNER JOIN issues dependent_issues ON dependent_issues.id = issue_dependencies.issue_id
        INNER JOIN issues depends_on_issues ON depends_on_issues.id = issue_dependencies.depends_on_issue_id
      SQL
      local = dependencies.where(issue_id: issue_ids, depends_on_issues: { github_state: "open" })
        .where.not(depends_on_issues: { paid_state: Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES })
        .where("dependent_issues.parent_issue_id IS DISTINCT FROM issue_dependencies.depends_on_issue_id")
        .pluck(:issue_id, "depends_on_issues.github_number")
      deployment = dependencies.where(issue_id: issue_ids, requires_deployment: true)
        .where(depends_on_issues: { is_pull_request: true, deployed_at: nil })
        .where.not(depends_on_issues: { github_state: "open" }).pluck(:issue_id, "depends_on_issues.github_number")
      (local + deployment).each { |issue_id, number| labels[issue_id] << "##{number}" }
      issues.group_by { |issue| issue.project.account_id }.each do |account_id, account_issues|
        IssueDependency.where(issue_id: account_issues.map(&:id))
          .merge(IssueDependency.still_blocking_external_for_account(account_id))
          .pluck(:issue_id, :depends_on_owner, :depends_on_repo, :depends_on_number)
          .each { |issue_id, owner, repo, number| labels[issue_id] << "#{owner}/#{repo}##{number}" }
      end
      # Mirror the singleton +prerequisite_labels+ ordering: PR numbers sorted
      # numerically before lexicographic external refs, so a batched lane
      # renders identical messages to a direct CloseoutStatus.call.
      issues.to_h do |issue|
        numbers, externals = labels[issue.id].uniq.partition { |label| label.start_with?("#") }
        [ issue.id, numbers.sort_by { |label| label.delete_prefix("#").to_i } + externals.sort ]
      end
    end
    private_class_method :prerequisite_labels_for

    def self.admissible_issue_ids(issue)
      Automation::Strategies::AutoPick::DefaultCandidateSource
        .eligible_scope(issue.project).pluck(:id)
    end

    # Each diagnostic interrogates the same persisted state consumed by the
    # candidate source. Keep this list additive: simultaneous guards must all
    # be visible rather than having the first one conceal the rest.
    def self.admission_blockers(issue, prerequisites: prerequisite_labels(issue), inputs: nil)
      prerequisite_blockers(issue, labels: prerequisites) + operator_pause_blockers(issue) +
        run_in_flight_blockers(issue, inputs:) + trust_blockers(issue) + feature_hold_blockers(issue, inputs:) +
        analysis_backoff_blockers(issue, inputs:) + scanner_verification_blockers(issue, inputs:) +
        open_native_child_blockers(issue, inputs:) + human_prerequisite_blockers(issue, inputs:)
    end

    # The scoped preflight is the admission authority. If it rejects after all
    # known guard diagnostics, do not invent a likely cause: callers get an
    # explicit investigation path and the exact dequeue decision remains safe.
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
        code: :unavailable,
        message: "The scoped dequeue admission check rejected this issue, but its exact guard is unavailable.",
        evidence: { "issue_id" => issue.id, "project_id" => issue.project_id },
        recovery: "Investigate the auto-pick eligibility trace and runner configuration, then request continuation again."
      )
    end

    def self.prerequisite_blockers(issue, labels: prerequisite_labels(issue))
      return [] if labels.empty?

      [ Blocker.new(
        code: :unmet_prerequisites,
        message: "Unresolved prerequisite work (#{labels.join(', ')}) must be resolved or linked before continuation.",
        evidence: { "prerequisites" => labels },
        recovery: "Resolve the listed prerequisite work or update its dependency link, then request continuation again."
      ) ]
    end

    # These are direct exclusions in DefaultCandidateSource, not dependency
    # edges. Keep their diagnostics separate so an operator never has to add a
    # redundant IssueDependency merely to learn why continuation is refused.
    # @spec PARTIAL-CLOSEOUT-030
    def self.open_native_child_blockers(issue, inputs: nil)
      children = if inputs
        inputs.native_children_by_issue_id.fetch(issue.id, [])
      else
        open_native_children_for([ issue ]).fetch(issue.id, [])
      end
      return [] if children.empty?

      references = children.map { |child| "##{child.github_number}" }
      [ Blocker.new(
        code: :open_native_children,
        message: "Open native child work (#{references.join(', ')}) prevents continuation.",
        evidence: { "children" => children.map { |child| native_child_evidence(child) } },
        recovery: "Complete or explicitly resolve the remaining work in #{references.join(', ')} before continuing; do not close a child merely to admit this issue."
      ) ]
    end

    # @spec PARTIAL-CLOSEOUT-030
    def self.human_prerequisite_blockers(issue, inputs: nil)
      notifications = if inputs
        inputs.prerequisite_notifications_by_issue_id.fetch(issue.id, [])
      else
        active_prerequisite_notifications_for([ issue ]).fetch(issue.id, [])
      end
      return [] if notifications.empty?

      references = notifications.map { |notification| "notification ##{notification.id}" }
      [ Blocker.new(
        code: :human_prerequisite,
        message: "Active partial-closeout #{references.join(', ')} requires unresolved human decision or evidence.",
        evidence: { "notifications" => notifications.map { |notification| prerequisite_notification_evidence(notification) } },
        recovery: "Follow the recorded guidance for #{references.join(', ')}: #{notifications.map(&:description).join(' ')} Do not dismiss it merely to admit this issue."
      ) ]
    end

    def self.operator_pause_blockers(issue)
      blockers = []
      if issue.paused? || issue.project.paused? || issue.project.quality_paused_at.present?
        blockers << Blocker.new(
          code: :operator_pause,
          message: "An explicit pause is active (the issue or its project is paused), and a continuation never bypasses it.",
          recovery: "An authorized operator must remove the explicit pause."
        )
      end
      if issue.paid_state.in?(%w[needs_input manual_review])
        blockers << Blocker.new(
          code: :operator_pause,
          message: "The issue is waiting for a human decision (#{issue.paid_state.tr('_', ' ')}); resolve that state first.",
          recovery: "Record the required human decision before authorizing new work."
        )
      end
      if issue.runner_retry_abandoned_at.present?
        blockers << Blocker.new(
          code: :operator_pause,
          message: "The issue is retry-abandoned; clear the retry-cap flag from the retry-limited lane first.",
          recovery: "Resolve the retry-limited incident before requesting continuation."
        )
      end

      hit_labels = Array(issue.labels).select { |label| skip_label_set(issue).include?(label.to_s.downcase) }
      if hit_labels.any?
        blockers << Blocker.new(
          code: :operator_pause,
          message: "An auto-pick skip label (#{hit_labels.join(', ')}) deliberately holds this issue out of scheduling.",
          evidence: { "labels" => hit_labels }, recovery: "Remove the skip label if new automated work is authorized."
        )
      end
      blockers
    end

    def self.run_in_flight_blockers(issue, inputs: nil)
      active = inputs ? inputs.active_run_issue_ids.include?(issue.id) : issue.agent_runs.where(status: AgentRun::AUTO_PICK_BLOCKING_STATUSES).exists?
      return [] unless active

      [ Blocker.new(code: :run_in_flight, message: "An agent run is already queued or in flight for this issue.",
        recovery: "Wait for the active run to finish before requesting another continuation.") ]
    end

    def self.trust_blockers(issue)
      trusted = issue.project.trusted_github_author_logins
      return [] if trusted.blank?
      return [] if trusted.map(&:downcase).include?(issue.github_creator_login.to_s.downcase)

      [ Blocker.new(
        code: :untrusted,
        message: "The issue creator (@#{issue.github_creator_login}) is not in the project's trusted allowlist.",
        evidence: { "creator" => issue.github_creator_login }, recovery: "An administrator must update the trusted-author policy."
      ) ]
    end

    def self.feature_hold_blockers(issue, inputs: nil)
      admission = FeatureIntents::RunAdmission.call(issue: issue, links: inputs&.feature_links_by_issue_id&.fetch(issue.id, []))
      return [] if admission.allowed?

      [ Blocker.new(code: :feature_held, message: admission.reason || "A feature release gate holds this issue.",
        recovery: "Complete the feature release or design-revision gate before continuing.") ]
    end

    # Mirrors the `apply_issue_analysis_backoff` eligibility filter via the
    # canonical `Issue#issue_analysis_backoff_active?` predicate, so an
    # evidence-carrying issue cooling down after provider exhaustion refuses
    # continuation with the specific wait-until reason instead of queueing a
    # run the dequeue recheck would cancel.
    # @spec PARTIAL-CLOSEOUT-004
    def self.analysis_backoff_blockers(issue, inputs: nil)
      next_attempt_at = issue.issue_analysis_next_attempt_at
      return [] if next_attempt_at.blank? || next_attempt_at <= Time.current

      reset_at = inputs ? inputs.analysis_backoff_reset_by_project_id.fetch(issue.project_id) : Issues::IssueAnalysisBackoffResetContext.call(project: issue.project)
      return [] unless issue.issue_analysis_backoff_active?(reset_at: reset_at)

      [ Blocker.new(
        code: :analysis_backoff,
        message: "Automatic issue analysis is in a provider-exhaustion backoff until " \
                 "#{next_attempt_at.utc.iso8601}; wait for the window to clear (or restore a " \
                 "capable runner to reset it) before requesting a continuation.",
        evidence: { "next_attempt_at" => next_attempt_at.utc.iso8601 },
        recovery: "Wait until #{next_attempt_at.utc.iso8601}, or restore a capable runner."
      ) ]
    end

    # @spec PARTIAL-CLOSEOUT-012 EAGER-QUEUE-013 EAGER-QUEUE-015
    def self.scanner_verification_blockers(issue, inputs: nil)
      return [] unless issue.source == Issue::SYNTHETIC_CODE_SCANNING_SOURCE

      attempt = inputs ? inputs.scanner_attempts_by_issue_id[issue.id] : issue.code_scanning_remediation_attempts.latest_per_issue.first
      return [] unless attempt&.status.in?(%w[awaiting_verification verification_failed verification_blocked])

      [ scanner_blocker(issue, attempt) ]
    end

    def self.scanner_blocker(issue, attempt)
      code, state, recovery = scanner_state(attempt)
      Blocker.new(
        code: code,
        message: "Code-scanning alert ##{scanner_alert_number(issue)} #{state}; merge evidence is not proof it is fixed.",
        evidence: scanner_evidence(issue, attempt),
        recovery: recovery
      )
    end

    def self.scanner_state(attempt)
      case attempt.status
      when "awaiting_verification"
        [ :scanner_verification_pending, "awaits post-merge verification", "Wait for the next matching default-branch scan." ]
      when "verification_blocked"
        [ :scanner_verification_retryable, "has retryable verification evidence", "Wait for or repair scanner verification, then let the verifier retry." ]
      else
        [ :scanner_verification_failed, "has a scanner-confirmed recurrence after matching post-merge verification", "Review the failed verification and explicitly authorize new remediation if appropriate." ]
      end
    end

    def self.scanner_evidence(issue, attempt)
      {
        "attempt_id" => attempt.id, "attempt_url" => issue.github_url,
        "alert_number" => scanner_alert_number(issue), "recurrent" => attempt.status == "verification_failed",
        "pull_request_number" => attempt.pull_request_number,
        "analysis_id" => attempt.verification_analysis_id,
        "analysis_commit_sha" => attempt.verification_commit_sha,
        "status" => attempt.status, "blocked_reason" => attempt.blocked_reason
      }.compact
    end

    def self.scanner_alert_number(issue)
      issue.github_issue_id - Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET
    end

    def self.prerequisite_labels(issue)
      local = (issue.blocking_issues.pluck(:github_number) +
        issue.blocking_deployment_dependencies.map { |dep| dep.depends_on_issue.github_number }).uniq.sort
      external = issue.blocking_external_dependencies.map do |dep|
        "#{dep.depends_on_owner}/#{dep.depends_on_repo}##{dep.depends_on_number}"
      end

      local.map { |number| "##{number}" } + external.sort
    end

    def self.open_native_children_for(issues)
      children = Issue.where(parent_issue_id: issues.map(&:id), is_pull_request: false, github_state: "open")
        .where.not(paid_state: Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES)
        .order(:github_number, :id).to_a
      children.group_by(&:parent_issue_id)
    end
    private_class_method :open_native_children_for

    def self.active_prerequisite_notifications_for(issues)
      notifications = Notification.where(
        account_id: issues.map { |issue| issue.project.account_id }.uniq,
        source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
        subject_type: "Issue",
        subject_id: issues.map(&:id),
        resolved_at: nil,
        dismissed_at: nil
      ).order(:id).to_a
      notifications.group_by(&:subject_id)
    end
    private_class_method :active_prerequisite_notifications_for

    def self.native_child_evidence(child)
      { "id" => child.id, "number" => child.github_number, "url" => child.github_url }
    end
    private_class_method :native_child_evidence

    def self.prerequisite_notification_evidence(notification)
      {
        "id" => notification.id,
        "title" => notification.title,
        "description" => notification.description,
        "action_url" => notification.action_url
      }.compact
    end
    private_class_method :prerequisite_notification_evidence

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
