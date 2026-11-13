# frozen_string_literal: true

module Automation
  # Shared fail-closed admission check for every action after delegated work
  # has been admitted. Callers supply current, already-resolved policy facts;
  # this service compares them with the authorization and routes a mismatch.
  # @spec PROJECT-DELEGATION-004 @spec PROJECT-DELEGATION-006
  # @spec BOUNDED-PHASE-AUTHORIZATION-004
  class DelegatedWorkBoundary
    BOUNDARIES = %i[create queue dequeue retry follow_up repair closeout].freeze
    NOTIFICATION_SOURCE = "delegated_work_boundary_recheck"

    Result = Data.define(:permitted, :boundary, :reasons, :notification) do
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
      return Result.new(permitted: true, boundary:, reasons: [], notification: nil) if reasons.empty?

      notification = FocusedDecision.call(
        account: authorization.account,
        subject: authorization.issue,
        source: NOTIFICATION_SOURCE,
        title: "Delegated work needs a focused decision",
        description: "Delegated work is paused before #{boundary} until its current authority is reviewed.",
        metadata: { "authorization_id" => authorization.id, "boundary" => boundary.to_s, "reasons" => reasons.map(&:to_s) }
      )
      ProjectDelegation::RecordPilotEvent.boundary_stop(authorization:, reasons:, boundary:)
      Result.new(permitted: false, boundary:, reasons:, notification:)
    end

    private

    attr_reader :authorization, :boundary, :snapshot

    def validate_boundary!
      return if BOUNDARIES.include?(boundary)

      raise ArgumentError, "unsupported delegated-work boundary: #{boundary}"
    end

    def failed_checks
      checks = {
        authorization_lifecycle: authorization.allowed?,
        expiry: !authorization.expired?,
        intent_revision: revision_matches?(:intent_revision),
        acceptance_revision: revision_matches?(:acceptance_revision),
        evidence_revision: revision_matches?(:evidence_revision),
        posture_signature: revision_matches?(:posture_signature),
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
        explicit_hold: !truthy?(snapshot[:explicit_hold])
      }
      reasons = checks.filter_map { |reason, passed| reason unless passed }
      complete_at_stop if reasons.include?(:bounded_stop) && at_exclusive_stop?
      reasons
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

    def complete_at_stop
      authorization.complete! if authorization.status == "active"
    end

    def at_exclusive_stop?
      stop = authorization.evidence.to_h["stop_before_phase"]
      stop.present? && snapshot[:phase].to_s == stop.to_s
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
  end

  DelegatedWorkBoundaryRecheck = DelegatedWorkBoundary
end
