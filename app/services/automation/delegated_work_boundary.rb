# frozen_string_literal: true

module Automation
  # Shared fail-closed admission check for every action after delegated work
  # has been admitted. Callers supply current, already-resolved policy facts;
  # this service compares them with the admission snapshot and routes a
  # mismatch.
  #
  # The posture comparison is directional. The admission snapshot pins the
  # delegation posture the work was admitted under, so a later change is read
  # as a narrowing (the next action stops) or as a broadening (the broader
  # authority applies only to new admissions, never to the in-flight one).
  # Every stop names the recovery that stays inside the admitted lineage.
  #
  # @spec PROJECT-DELEGATION-004 @spec PROJECT-DELEGATION-006
  # @spec PROJECT-DELEGATION-009 @spec PROJECT-DELEGATION-010
  # @spec BOUNDED-PHASE-AUTHORIZATION-004
  class DelegatedWorkBoundary
    BOUNDARIES = %i[create queue dequeue retry follow_up repair closeout].freeze
    NOTIFICATION_SOURCE = "delegated_work_boundary_recheck"

    # The recovery each stop names. Every one of them stays inside the
    # admitted lineage: none opens new work, refreshes a stale review, or
    # extends the delegated scope.
    RECOVERY_SCOPES = {
      authorization_expired: "reauthorize",
      authorization_revoked: "reauthorize",
      authorization_inactive: "reauthorize",
      posture_narrowed: "re_admit",
      posture_broadened: "re_admit",
      delegation_hold: "release_hold",
      bounded_stop: "technical_stop_recovery"
    }.freeze
    DEFAULT_RECOVERY = "human_decision"

    Result = Data.define(:permitted, :boundary, :reasons, :notification, :recovery) do
      def permitted? = permitted
      def blocked? = !permitted
    end

    def self.call(...)
      new(...).call
    end

    def initialize(authorization:, boundary:, snapshot:)
      @authorization = authorization
      @boundary = boundary.to_sym
      @snapshot = snapshot.to_h.deep_symbolize_keys
    end

    def call
      validate_boundary!
      reasons = failed_checks
      return Result.new(permitted: true, boundary:, reasons: [], notification: nil, recovery: nil) if reasons.empty?

      recovery = recovery_for(reasons)
      notification = FocusedDecision.call(
        account: authorization.account,
        subject: authorization.issue,
        source: NOTIFICATION_SOURCE,
        title: "Delegated work needs a focused decision",
        description: "Delegated work is paused before #{boundary} until its current authority is reviewed. " \
          "Recovery: #{recovery}.",
        metadata: {
          "authorization_id" => authorization.id,
          "boundary" => boundary.to_s,
          "reasons" => reasons.map(&:to_s),
          "recovery" => recovery
        }
      )
      ProjectDelegation::RecordPilotEvent.boundary_stop(authorization:, reasons:, boundary:)
      Result.new(permitted: false, boundary:, reasons:, notification:, recovery:)
    end

    private

    attr_reader :authorization, :boundary, :snapshot

    def validate_boundary!
      return if BOUNDARIES.include?(boundary)

      raise ArgumentError, "unsupported delegated-work boundary: #{boundary}"
    end

    def failed_checks
      checks = {
        intent_revision: revision_matches?(:intent_revision),
        acceptance_revision: revision_matches?(:acceptance_revision),
        evidence_revision: revision_matches?(:evidence_revision),
        phase: phase_matches?,
        phase_policy: policy_allows?(snapshot[:phase_policy]),
        bounded_stop: bounded_stop_allows?,
        tenant: tenant_matches?,
        # Security is unavailable until a canonical assessment producer adds
        # it to the admission snapshot. Its absence fails closed so an
        # unverified boundary cannot preserve or broaden delegated authority.
        security: truthy?(snapshot[:security]),
        trust: truthy?(snapshot[:trust]),
        budget: allowed?(snapshot[:budget]),
        repository_controls: allowed?(snapshot[:repository_controls]),
        assessment_availability: truthy?(snapshot[:assessment_available]),
        # An explicit hold pauses delegated work for the project. The fact is
        # only true when the project has no active hold, so an unresolved hold
        # fails closed like every other boundary fact.
        delegation_hold: snapshot[:delegation_hold] == false
      }
      reasons = checks.filter_map { |reason, passed| reason unless passed }
      reasons.unshift(authorization_reason) if authorization_reason
      reasons << posture_reason if posture_reason
      reasons
    end

    # The posture stop names itself: an admission without a posture binding,
    # a posture that grants less authority than the admission relied on, and
    # a posture that grants more are three different situations.
    def posture_reason
      case posture_comparison
      when :unbound then :posture_binding
      when :narrowed then :posture_narrowed
      when :broadened then :posture_broadened
      end
    end

    # The lifecycle stop names itself: a revoked authorization, an expired
    # authorization, and any other terminal state are different recoveries.
    def authorization_reason
      return :authorization_revoked if authorization.revoked?
      return :authorization_expired if authorization.expired?
      return :authorization_inactive unless authorization.allowed?

      nil
    end

    # The direction-aware posture comparison between the admission's pinned
    # snapshot and the posture the project grants now.
    # @spec PROJECT-DELEGATION-009
    def posture_comparison
      admitted = admitted_posture_snapshot
      current = current_posture_snapshot
      return :unbound if admitted.blank? || current.blank?

      admitted_classes = delegated_classes(admitted)
      current_classes = delegated_classes(current)
      return :narrowed unless (admitted_classes - current_classes).empty?
      return :broadened unless (current_classes - admitted_classes).empty?

      :current
    end

    def posture_binding?
      posture_comparison == :current
    end

    def admitted_posture_snapshot
      authorization.evidence.to_h["posture_snapshot"].to_h.deep_stringify_keys
    end

    def current_posture_snapshot
      snapshot[:posture_snapshot].to_h.deep_stringify_keys
    end

    def delegated_classes(posture_snapshot)
      Array(posture_snapshot["enabled_action_classes"]).map(&:to_s)
    end

    def revision_matches?(key)
      expected = authorization.evidence.to_h[key.to_s]
      expected.present? && snapshot[key].to_s == expected.to_s
    end

    def phase_matches?
      expected = authorization.evidence.to_h["phase"]
      expected.present? && snapshot[:phase].to_s == expected.to_s
    end

    def bounded_stop_allows?
      stop = authorization.evidence.to_h["stop_before_phase"]
      stop.present? && snapshot[:phase].to_s != stop.to_s
    end

    # Fail closed: a caller that could not resolve the current phase policy
    # supplies nil, and nil is never an implicit permit. The check reports
    # :phase_policy so the focused decision says the policy was unavailable.
    def policy_allows?(policy)
      policy.present? && allowed?(policy) == true
    end

    def tenant_matches?
      snapshot[:account_id].to_s == authorization.account_id.to_s &&
        snapshot[:project_id].to_s == authorization.project_id.to_s &&
        snapshot[:issue_id].to_s == authorization.issue_id.to_s
    end

    def allowed?(value)
      return value.allowed? if value.respond_to?(:allowed?)
      return value.permitted? if value.respond_to?(:permitted?)
      return value if value == true || value == false

      value.to_h[:allowed] == true || value.to_h["allowed"] == true if value.respond_to?(:to_h)
    end

    def truthy?(value)
      value == true || value == "true"
    end

    def recovery_for(reasons)
      reasons.filter_map { |reason| RECOVERY_SCOPES[reason] }.first || DEFAULT_RECOVERY
    end
  end

  DelegatedWorkBoundaryRecheck = DelegatedWorkBoundary
end
