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
  # A work item whose action class has no bounded authorization is not
  # delegated work under this contract: +call+ returns nil and the caller
  # applies its ordinary policy. Manual and automatic actions on a delegated
  # work item both recheck at their boundary, so a retry cannot outlive a
  # revoked or stale authorization.
  #
  # @spec PROJECT-DELEGATION-004 @spec PROJECT-DELEGATION-006
  # @spec BOUNDED-PHASE-AUTHORIZATION-004
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
      "merge" => Automation::Phases::MERGE
    }.freeze

    STOP_BEFORE_PHASES = {
      "review" => Automation::Phases::MERGE,
      "repair" => Automation::Phases::MERGE,
      "merge" => "release_deployment"
    }.freeze

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

    def self.acceptance_revision_for(assessment)
      "criteria:#{Digest::SHA256.hexdigest(assessment.criteria.to_json)}"
    end

    # Posture signature: digest of the project's current phase-policy
    # settings, so broadening or narrowing delegated posture after admission
    # fails the next boundary recheck (the authorization keeps its pinned
    # posture; only a new admission picks up the broader one).
    def self.posture_signature_for(project:, action:)
      EffectivePolicyNotice.new(
        project: project,
        phase: ACTION_PHASES.fetch(action),
        endpoint: ACTION_PHASES.fetch(action),
        continuation_selected: true
      ).signature
    end

    # The canonical bounded evidence an authorization for this work item and
    # action must pin so every later boundary recheck can re-derive and match
    # it. Admission surfaces build their evidence through this helper so the
    # admission and recheck sides of the contract cannot drift.
    def self.admission_evidence(work_item:, action:, acceptance_refs:, stop_before_phase:)
      {
        "intent_digest" => "sha256:#{PartialCloseouts::Assessment.intent_revision_for(work_item)}",
        "acceptance_refs" => acceptance_refs,
        **revision_tokens(issue: work_item),
        "posture_signature" => posture_signature_for(project: work_item.project, action: action),
        "phase" => ACTION_PHASES.fetch(action),
        "stop_before_phase" => stop_before_phase
      }
    end

    def self.call(project:, issue: nil, pull_request_number: nil, goal: nil, action: nil,
      boundary:, trigger: :automatic)
      work_item = issue || work_item_for(project:, pull_request_number:)
      delegated_action = action || GOAL_ACTIONS[goal.to_s]
      return nil if work_item.nil? || delegated_action.nil?

      new(work_item: work_item, action: delegated_action, boundary: boundary).call
    end

    def initialize(work_item:, action:, boundary:)
      @work_item = work_item
      @action = action
      @boundary = boundary
    end

    # Returns a DelegatedWorkBoundary::Result, or nil when the work item is
    # not governed by a bounded authorization for this action.
    def call
      return nil if authorization.nil?

      authorization.with_lock do
        DelegatedWorkBoundary.call(authorization:, boundary:, snapshot:)
      end
    end

    private

    attr_reader :work_item, :action, :boundary

    def project
      work_item.project
    end

    # The latest authorization for this action governs the lineage — a newer
    # explicit authorization supersedes older ones, and a revoked, expired,
    # or completed terminal authorization blocks new actions until a new
    # explicit authorization exists (it never falls through to project
    # defaults for that lineage).
    def authorization
      @authorization ||= work_item.bounded_delegated_actions
        .where(action: action)
        .order(id: :desc)
        .first
    end

    def snapshot
      current_assessment = assessment
      {
        account_id: project.account_id,
        project_id: project.id,
        issue_id: work_item.id,
        **self.class.revision_tokens(issue: work_item, assessment: current_assessment).transform_keys(&:to_sym),
        posture_signature: self.class.posture_signature_for(project:, action:),
        phase: ACTION_PHASES.fetch(action),
        phase_policy: EffectivePolicy.call(project:, phase: ACTION_PHASES.fetch(action),
          work_item:, trigger: :automatic),
        trust: !work_item.untrusted?,
        budget: CostBudgets::Check.call(project),
        repository_controls: project.github_installation&.active? == true,
        assessment_available: !current_assessment.stale?
      }
    end

    def assessment
      @assessment ||= PartialCloseouts::Assessment.call(work_item)
    end
  end
end
