# frozen_string_literal: true

module Inbox
  # Cheap, approximate count of the current user's inbox entries for the nav
  # badge. Unlike Inbox::Queue, this never loads issue bodies or parses
  # clarifying questions per candidate — it counts needs_input rows on the
  # operator's visible projects plus open plan reviews, cached for a short
  # TTL per user.
  # Questionless needs_input rows are invalid and repaired during sync, so
  # counting them here (without a question-presence check) is a deliberate,
  # bounded approximation rather than a rendering bug.
  class Count
    CACHE_TTL = 90.seconds
    ROLLOUT_PROBE_TTL = 30.seconds
    DISPLAY_CAP = 99

    def self.call(...)
      new(...).call
    end

    def initialize(user:)
      @user = user
    end

    # @spec OPERATOR-INBOX-010
    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { compute_count }
    end

    private

    attr_reader :user

    # @spec INBOX-PHASE-RELEVANCE-005 @spec INBOX-PHASE-RELEVANCE-009
    # When any visible project runs the phase model, the count applies that
    # policy to Availability's count-oriented per-project projection. Personal
    # removal is rollout-independent, but only requires resolving each removed
    # request; rebuilding every Inbox entry on a cache miss is unnecessary.
    # Otherwise the cheap SQL approximation is unchanged.
    def compute_count
      return governed_count if phase_model_governed?

      count = needs_input_count + open_plan_review_count + merge_approval_count + action_required_count +
        escalated_pr_count + manual_review_count + intent_conformance_count + feature_decision_count +
        retry_limited_count + change_intent_draft_count + partial_closeout_count +
        test_review_pending_count + project_setup_pending_count + traceability_gap_count +
        layered_verification_finding_count
      return count unless personal_removals?

      [ count - suppressed_removal_count, 0 ].max
    end

    def governed_count
      count = Inbox::Availability.call(user: user).count_matrix.sum do |entry_kind, counts|
        counts.sum { |project_id, value| phase_relevant?(entry_kind, project_id) ? value : 0 }
      end
      count -= suppressed_removal_count if personal_removals?
      count.clamp(0, DISPLAY_CAP)
    end

    def phase_relevant?(entry_kind, project_id)
      return true unless governed_project_ids.include?(project_id)

      phase = Inbox::PhaseOwnership::KIND_PHASES[entry_kind]
      phase.blank? || Automation::PhaseSettings.phase_enabled?(projects_by_id.fetch(project_id), phase)
    end

    def projects_by_id
      @projects_by_id ||= Project.where(id: visible_project_ids).index_by(&:id)
    end

    def phase_model_governed?
      governed_project_ids.any?
    end

    def governed_project_ids
      @governed_project_ids ||= Rails.cache.fetch(
        "inbox/count/governed/#{user.id}", expires_in: ROLLOUT_PROBE_TTL
      ) do
        Automation::RolloutGuard.enabled_project_ids(visible_project_ids).sort
      end
    end

    def personal_removals?
      active_removals.any?
    end

    # A removal can only have been created for a real queue entry. Resolve its
    # one lane and record rather than materializing every lane just to apply a
    # presentation-only suppression. `find_entry` also rechecks the current
    # occurrence, so stale removal rows do not lower the badge.
    #
    # Every lane summed into `count` is a raw SQL/policy count that ignores
    # personal removals, except `feature_decision_count`, which comes from
    # Inbox::Queue.call — whose #apply_scope already rejects suppressed entries.
    # Feature-decision removals are therefore excluded from `count` before this
    # subtraction, so skipping them here avoids subtracting the same removal
    # twice and keeps the badge in agreement with the rendered list.
    # @spec INBOX-PHASE-RELEVANCE-009
    def suppressed_removal_count
      active_removals.count do |removal|
        next false if removal.entry_kind == Inbox::Queue::FEATURE_DECISION_KIND

        entry = Inbox::Queue.find_entry(user:, entry_id: removal.request_key)
        entry && removal.suppresses?(Inbox::RequestIdentity.occurrence_for(entry))
      end
    end

    def active_removals
      @active_removals ||= InboxRemoval.active.where(user: user).to_a
    end

    def needs_input_count
      project_ids = visible_project_ids
      return 0 if project_ids.empty?

      Issue.where(project_id: project_ids, paid_state: "needs_input", github_state: "open").count
    end

    def open_plan_review_count
      PlanReviewPolicy::Scope.new(user, DecompositionDecision).resolve.open_plan_reviews.count
    end

    # @spec FEATURE-APPROVAL-020
    def feature_decision_count
      Inbox::Queue.call(user: user, kind: Inbox::Queue::FEATURE_DECISION_KIND).size
    end

    def merge_approval_count
      project_ids = visible_project_ids
      return 0 if project_ids.empty?

      Inbox::MergeApproval.candidates(project_ids).count { |issue| Inbox::MergeApproval.call(issue).present? }
    end

    # Excludes notifications whose subject cannot be projected into a visible
    # inbox project. Runner-scoped blocking notifications borrow the owner's
    # first visible project so they can render in the queue without a
    # runner-specific inbox lane.
    def action_required_count
      notifications = NotificationPolicy::Scope.new(user, Notification).resolve.active.blocking
        .includes(:subject)
        .to_a
      Notification.preload_resolved_projects(notifications)
      preload_runner_users(notifications)
      notifications.count { |notification| project_for(notification).present? }
    end

    # A direct indexed count, unlike merge_approval_count: escalation is a
    # column value, not a signal snapshot that needs a Ruby-side check.
    # @spec OPERATOR-INBOX-002C
    def escalated_pr_count
      project_ids = visible_project_ids
      return 0 if project_ids.empty?

      Issue.where(project_id: project_ids, is_pull_request: true, github_state: "open", pr_review_phase: "escalated").count
    end

    # A direct indexed count, unlike merge_approval_count: manual_review is a
    # paid_state value, not a signal snapshot that needs a Ruby-side check.
    # @spec OPERATOR-INBOX-002D
    def manual_review_count
      project_ids = visible_project_ids
      return 0 if project_ids.empty?

      Issue.where(project_id: project_ids, paid_state: "manual_review", github_state: "open").count
    end

    # Mirrors merge_approval_count's shape: a cheap SQL pre-filter narrows to
    # rows that could plausibly carry the intent_conformance blocker before
    # falling back to Ruby for the full Inbox::IntentConformance check.
    # @spec INTENT-CONFORMANCE-006
    def intent_conformance_count
      project_ids = visible_project_ids
      return 0 if project_ids.empty?

      Inbox::IntentConformance.candidates(project_ids).count { |issue| Inbox::IntentConformance.call(issue).present? }
    end

    # A direct indexed count: both abandonment producers (runner-retry-cap and
    # push-permission rejection) write the same `runner_retry_abandoned_at`
    # column, so the lane is a single WHERE NOT NULL scan with no paid_state
    # filter.
    # @spec OPERATOR-INBOX-002E
    def retry_limited_count
      project_ids = visible_project_ids
      return 0 if project_ids.empty?

      Issue.where(project_id: project_ids, github_state: "open")
        .where.not(runner_retry_abandoned_at: nil)
        .count
    end

    # @spec CHANGE-INTENT-INBOX-001
    # Change Intent Records follow project membership visibility, independent
    # of the account+owner visibility used by issue-backed inbox lanes.
    def change_intent_draft_count
      ChangeIntentPolicy::Scope.new(user, ChangeIntent).resolve.pending_review.count
    end

    # A direct indexed count sharing the exact lane computation with
    # Inbox::Queue (test_review_pending_issues) so the badge can never
    # disagree with the list, the same sharing partial_closeout_count does.
    # @spec OPERATOR-INBOX-002J
    def test_review_pending_count
      project_ids = visible_project_ids
      return 0 if project_ids.empty?

      Inbox::Queue.test_review_pending_issues(project_ids).count
    end

    # @spec PROJECT-READINESS-005
    def project_setup_pending_count
      Project.where(id: visible_project_ids).select(&:readiness_blocked?).count
    end

    # @spec DESIGN-RECONCILIATION-001 @spec OPERATOR-INBOX-020
    def traceability_gap_count
      DesignArtifactFinding.actionable_findings.where(project_id: visible_project_ids).count
    end

    # @spec LAYERED-VERIFY-015
    def layered_verification_finding_count
      LayeredVerificationFinding.where(project_id: visible_project_ids, status: %w[open deferred]).count
    end

    # Shares the exact lane computation with Inbox::Queue
    # (Issues::StalledCloseouts) so the badge can never disagree with the
    # list. The SQL prefilter on indexed state columns keeps the scan bounded;
    # the stall population is small by construction (terminal evidence plus no
    # operator hold and no work in flight).
    # @spec PARTIAL-CLOSEOUT-002 @spec PARTIAL-CLOSEOUT-009
    def partial_closeout_count
      projects = Project.where(id: visible_project_ids)
        .includes(account: :tenant_setting, created_by: :user_setting).to_a
      return 0 if projects.empty?

      Issues::StalledCloseouts.call(projects).size
    end

    # Authorized Inbox visibility: account isolation plus per-owner
    # visibility, independent of automatic work-selection eligibility. See
    # `Inbox::Queue#visible_projects` — deliberately does NOT filter on
    # `auto_pick_enabled` or apply `Issues::AutoPickProjectGate` (#4221).
    def visible_project_ids
      @visible_project_ids ||= Project
        .where(
          account_id: user.account_id,
          created_by_id: visible_owner_ids,
          active: true
        )
        .pluck(:id)
    end

    def visible_owner_ids
      owner_ids = [ user.id ]
      owner_ids << nil if AgentRun.orphaned_project_owner?(user)
      owner_ids
    end

    def preload_runner_users(notifications)
      runners = notifications.filter_map(&:subject).select { |subject| subject.is_a?(Runner) }
      ActiveRecord::Associations::Preloader.new(records: runners, associations: :user).call
    end

    def project_for(notification)
      return runner_projects_by_user_id[notification.subject.user_id]&.first if notification.subject.is_a?(Runner)

      notification.resolved_project
    end

    def runner_projects_by_user_id
      @runner_projects_by_user_id ||= Project
        .where(
          account_id: user.account_id,
          created_by_id: visible_owner_ids,
          active: true
        )
        .group_by(&:created_by_id)
    end

    def cache_key
      "inbox/count/#{user.account_id}/#{user.id}/#{Dashboard::CacheVersion.current(user.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)}/#{governed_project_ids.join("-")}"
    end
  end
end
