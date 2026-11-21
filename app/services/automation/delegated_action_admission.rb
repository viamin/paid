# frozen_string_literal: true

module Automation
  # Shared delegated-work admission contract (RDR-078 admission and
  # concurrency, RDR-080 surface parity): the one call every runtime
  # boundary uses before delegated work begins. Run queueing, dequeue,
  # retry, follow-up, repair, and merge execution all funnel through here.
  # It resolves the work item's governing bounded authorization and the
  # current boundary facts, then rechecks them through DelegatedWorkBoundary,
  # which fails closed and routes a mismatch to one focused Inbox decision.
  #
  # A work item whose action class has no bounded authorization covering it is
  # not delegated work under this contract: +call+ returns nil and the caller
  # applies its ordinary policy. Manual and automatic actions on a delegated
  # work item both recheck at their boundary, so a retry cannot outlive a
  # revoked or stale authorization.
  #
  # @spec PROJECT-DELEGATION-004 @spec PROJECT-DELEGATION-006
  # @spec BOUNDED-PHASE-AUTHORIZATION-001 @spec BOUNDED-PHASE-AUTHORIZATION-004
  # @spec BOUNDED-PHASE-AUTHORIZATION-005 @spec BOUNDED-PHASE-AUTHORIZATION-006
  class DelegatedActionAdmission
    # Run goals whose delegated action class is bounded by a
    # BoundedDelegatedAction. Goals absent here (create_pr, enhance_issue,
    # ...) have no bounded action and are never delegated work.
    GOAL_ACTIONS = {
      "review" => "review",
      "layered_verification_repair" => "repair"
    }.freeze

    # The delivery phase each delegated action executes in. Merging is how
    # delegated delivery work closes, so the merge action is checked at the
    # closeout boundary.
    ACTION_PHASES = {
      "review" => Automation::Phases::CODING,
      "repair" => Automation::Phases::CODING,
      "merge" => Automation::Phases::MERGE,
      "issue_closure" => Automation::Phases::MERGE
    }.freeze

    STOP_BEFORE_PHASES = {
      "review" => Automation::Phases::MERGE,
      "repair" => Automation::Phases::MERGE,
      "merge" => "release_deployment"
    }.freeze

    ACTION_CLASSES = EffectivePolicy::ACTION_CLASS_BY_DELEGATED_ACTION.freeze

    # The work item for a run: its issue when issue-scoped, otherwise the
    # project's PR row for a PR-scoped run (review goals).
    def self.work_item_for(project:, issue_id: nil, pull_request_number: nil)
      return Issue.find_by(id: issue_id) if issue_id

      return nil if pull_request_number.blank?

      project.issues.find_by(github_number: pull_request_number, is_pull_request: true)
    end

    # Canonical current revision tokens. Admission surfaces pin these exact
    # tokens (plus phase and stop_before_phase) in the authorization's
    # evidence so each boundary recheck can prove the authorization is still
    # current instead of trusting it. Sources:
    # - intent: the work item's title/body digest
    # - acceptance: the current recorded assessment's criteria digest
    # - evidence: the closeout-evidence and technical-prerequisite digest
    def self.revision_tokens(issue:, assessment: PartialCloseouts::Assessment.call(issue))
      {
        "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
        "acceptance_revision" => acceptance_revision_for(assessment),
        "evidence_revision" => assessment.current_source_revision
      }
    end

    # The established same-work lineage of a work item — the root work item
    # and the pull requests linked to it, resolved through the existing
    # continuation lookup. Admissions pin this list so a later-linked or
    # unrelated work item cannot inherit the authorization.
    # @spec BOUNDED-PHASE-AUTHORIZATION-001
    def self.lineage_issue_ids(work_item)
      ContinuationGrantLookup.chain_issue_ids(work_item).sort
    end

    def self.acceptance_revision_for(assessment)
      "criteria:#{Digest::SHA256.hexdigest(assessment.criteria.to_json)}"
    end

    # Canonical policy signature: digest of the phase decision plus the
    # effective posture level, revision, and policy signature. Narrowing or a
    # guard rollback therefore invalidates an existing admission at the next
    # boundary recheck.
    def self.posture_signature_for(project:, action:)
      Digest::SHA256.hexdigest(EffectivePolicy.call(
        project:,
        phase: ACTION_PHASES.fetch(action),
        trigger: :automatic,
        delegated_action: action
      ).to_h.to_json)
    end

    # The canonical bounded evidence an authorization for this work item and
    # action must pin so every later boundary recheck can re-derive and match
    # it. Admission surfaces build their evidence through this helper so the
    # admission and recheck sides of the contract cannot drift. The pinned
    # lineage records the same-work chain the authorization governs.
    # @spec BOUNDED-PHASE-AUTHORIZATION-001
    def self.admission_evidence(work_item:, action:, acceptance_refs:, stop_before_phase:, action_evidence: {})
      {
        "intent_digest" => "sha256:#{PartialCloseouts::Assessment.intent_revision_for(work_item)}",
        "acceptance_refs" => acceptance_refs,
        **revision_tokens(issue: work_item),
        "posture_signature" => posture_signature_for(project: work_item.project, action: action),
        "phase" => ACTION_PHASES.fetch(action),
        "stop_before_phase" => stop_before_phase,
        BoundedDelegatedAction::LINEAGE_KEY => lineage_issue_ids(work_item),
        "action_evidence" => action_evidence.is_a?(Hash) ? action_evidence.stringify_keys : {}
      }
    end

    def self.call(project:, issue: nil, pull_request_number: nil, goal: nil, action: nil,
      action_evidence: {}, boundary:, trigger: :automatic)
      work_item = issue || work_item_for(project:, pull_request_number:)
      delegated_action = action || GOAL_ACTIONS[goal.to_s]
      return nil if work_item.nil? || delegated_action.nil?

      new(work_item: work_item, action: delegated_action, action_evidence:, boundary:, trigger:).call
    end

    # Successful execution reaches the action's exclusive stop. Completion is
    # deliberately separate from the pre-action recheck: before execution the
    # work item is still in ACTION_PHASES, not STOP_BEFORE_PHASES.
    # @spec PROJECT-DELEGATION-006
    def self.complete_at_exclusive_stop(issue:, phase:)
      STOP_BEFORE_PHASES.filter_map do |action, stop_phase|
        next unless stop_phase == phase.to_s

        new(work_item: issue, action: action, boundary: :closeout, trigger: :automatic)
          .complete_at_exclusive_stop
      end.any?
    end

    def initialize(work_item:, action:, action_evidence: {}, boundary:, trigger:)
      @work_item = work_item
      @action = action
      @action_evidence = action_evidence
      @boundary = boundary
      @trigger = trigger
    end

    # Returns a DelegatedWorkBoundary::Result, or nil when the work item is
    # not governed by a bounded authorization for this action.
    def call
      return nil if authorization.nil?

      scope_assessment = assess_scope
      authorization.with_lock do
        boundary_decision = DelegatedWorkBoundary.call(authorization:, boundary:, snapshot: scope_snapshot(scope_assessment:))
        return boundary_decision if boundary_decision.blocked?

        action_decision
      end
    end

    def complete_at_exclusive_stop
      return false unless authorization_at_expected_stop?

      authorization.complete!
    end

    private

    attr_reader :work_item, :action, :action_evidence, :boundary, :trigger

    def action_decision
      decision = ProjectDelegation::ActionPlan.call(
        project:, work_item:, action: ACTION_CLASSES.fetch(action), evidence: action_plan_evidence
      )
      return delegated_result(decision, notification: nil) if decision.permitted?

      notification = FocusedDecision.call(
        account: project.account,
        subject: work_item,
        source: DelegatedWorkBoundary::NOTIFICATION_SOURCE,
        title: "Delegated action needs a focused decision",
        description: "Delegated work is paused before #{boundary} until its action evidence is reviewed.",
        metadata: {
          "authorization_id" => authorization.id,
          "boundary" => boundary.to_s,
          "reasons" => decision.reasons
        }
      )
      delegated_result(decision, notification:)
    end

    def delegated_result(decision, notification:)
      DelegatedWorkBoundary::Result.new(
        permitted: decision.permitted?, boundary:, reasons: decision.reasons, notification:
      )
    end

    def action_plan_evidence
      authorization.admission_snapshot.slice(
        "intent_revision", "acceptance_revision", "evidence_revision", BoundedDelegatedAction::LINEAGE_KEY
      ).merge(
        "policy_signature" => ProjectDelegation::Posture.resolve(project).policy_signature
      ).merge(stored_action_evidence)
        .merge(normalized_action_evidence)
    end

    def stored_action_evidence
      value = authorization.admission_snapshot["action_evidence"]
      value.is_a?(Hash) ? value : {}
    end

    def normalized_action_evidence
      action_evidence.is_a?(Hash) ? action_evidence.stringify_keys : {}
    end

    def project
      work_item.project
    end

    # The latest authorization for this action that covers the admitted work
    # item through the established same-work lineage governs it — a newer
    # explicit authorization supersedes older ones, a work item outside the
    # pinned lineage is not delegated work under this contract (nil for that
    # lineage), and a revoked, expired, or completed terminal authorization
    # blocks new actions until a new explicit authorization exists (it never
    # falls through to project defaults for that lineage).
    # @spec BOUNDED-PHASE-AUTHORIZATION-002
    def authorization
      @authorization ||= BoundedDelegatedAction
        .for_lineage_of(work_item)
        .where(action: action)
        .find { |candidate| candidate.covers_issue_id?(work_item.id) }
    end

    def authorization_at_expected_stop?
      return false if authorization.nil?

      authorization.stop_before_phase.to_s == STOP_BEFORE_PHASES.fetch(action)
    end

    def scope_snapshot(scope_assessment:)
      current_assessment = assessment
      {
        account_id: project.account_id,
        project_id: project.id,
        issue_id: work_item.id,
        **self.class.revision_tokens(issue: pinned_work_item, assessment: current_assessment)
          .transform_keys(&:to_sym),
        posture_signature: self.class.posture_signature_for(project:, action:),
        phase: ACTION_PHASES.fetch(action),
        phase_policy: EffectivePolicy.call(project:, phase: ACTION_PHASES.fetch(action),
          work_item:, trigger:, delegated_action: action),
        security: security_assessment,
        trust: !work_item.untrusted?,
        budget: CostBudgets::Check.call(project),
        repository_controls: project.github_installation&.active? == true,
        assessment_available: !current_assessment.stale?,
        explicit_hold: work_item.held_for_review?
      }.merge(scope_assessment_snapshot(scope_assessment:))
    end

    # The work item whose pinned revisions the boundary recheck compares
    # against: the authorization's identified root. Lineage-governed work
    # (for example a linked pull request admitted under the root issue's
    # authorization) rechecks the pinned root's intent and acceptance, not
    # its own.
    # @spec BOUNDED-PHASE-AUTHORIZATION-002
    def pinned_work_item
      authorization.issue
    end

    def assessment
      @assessment ||= PartialCloseouts::Assessment.call(pinned_work_item)
    end

    # Pilot admissions retain their existing security controls. Expansion
    # requires a canonical assessment; until its producer exists, nil reaches
    # DelegatedWorkBoundary and fails closed.
    def security_assessment
      return true unless FeatureFlags.enabled?(:project_delegation_expansion, project:)

      nil
    end

    # Semantic assessment is intentionally completed before the authorization
    # lock. The locked snapshot below re-derives every deterministic admission
    # fact, so a revoke or any other lifecycle change during the remote request
    # still blocks admission.
    def assess_scope
      return unless action == "repair"

      AssessBoundedScope.call(authorization:, proposed_evidence: normalized_action_evidence)
    end

    def scope_assessment_snapshot(scope_assessment:)
      return { scope_correspondence: true, new_risk: false } unless action == "repair"

      { scope_correspondence: scope_assessment.in_scope?, new_risk: normalized_action_evidence["new_risk"] == true }
    end
  end
end
