# frozen_string_literal: true

module Automation
  # The only resolution path for a reassessment pause. Resume changes no
  # pinned evidence: revalidation is derived here from the current
  # authorization/boundary facts under the authorization lock, so a caller
  # cannot reopen a pause while its triggering condition still holds.
  # Intentionally slightly over the ~100-line class target: the resolution
  # policy and its fact re-derivation are one fail-closed contract.
  # @spec BOUNDED-PHASE-AUTHORIZATION-005
  class ResolveBoundedReassessment
    class Error < StandardError; end
    class PermissionDenied < Error; end
    class InvalidResolution < Error; end

    def self.call(...) = new(...).call

    def initialize(authorization:, user:, resolution:)
      @authorization = authorization
      @user = user
      @resolution = resolution.to_sym
    end

    def call
      ensure_permission!
      case resolution
      when :stop then stop
      when :resume then resume
      else raise InvalidResolution, "resolution must be stop or resume"
      end
    end

    private

    attr_reader :authorization, :user, :resolution

    def ensure_permission!
      return if ProjectPolicy.new(user, authorization.project).delegate_bounded_action?(authorization.action)

      raise PermissionDenied, "You do not have permission to resolve this bounded authorization."
    end

    def stop
      authorization.revoke!(user: user) || raise(InvalidResolution, "authorization is no longer resolvable")
      :stopped
    end

    def resume
      authorization.with_lock do
        raise InvalidResolution, "authorization is no longer resolvable" unless authorization.reassessment_required?

        ensure_triggers_resolved!
        authorization.resume_reassessment!
        Audit::RecordEvent.call(action: "bounded_action.reassessment_resumed", actor: user, subject: authorization,
          metadata: { "action" => authorization.action })
      end
      :resumed
    end

    def ensure_triggers_resolved!
      unresolved = unresolved_reasons
      return if unresolved.empty?

      raise InvalidResolution, "cannot resume while triggering conditions hold: #{unresolved.sort.join(", ")}"
    end

    # Deterministic reassessment triggers and the resume currency checks the
    # design mandates, re-derived from current facts so a stale pause cannot
    # be reopened on an assertion. Semantic triggers (new_risk,
    # scope_correspondence) describe proposed work rather than the stored
    # authorization: they are resolved by this authorized resume decision and
    # re-evaluated when the next admission assesses scope.
    def unresolved_reasons
      tokens = DelegatedActionAdmission.revision_tokens(issue: authorization.issue)
      {
        expiry: authorization.expires_at > Time.current,
        intent_revision: revision_matches?(tokens, "intent_revision"),
        acceptance_revision: revision_matches?(tokens, "acceptance_revision"),
        posture_signature: posture_signature_current?,
        phase_policy: policy_permits?,
        lineage: lineage_current?
      }.filter_map { |reason, passed| reason unless passed }
    end

    def revision_matches?(tokens, key)
      expected = authorization.evidence.to_h[key]
      expected.present? && tokens[key].to_s == expected.to_s
    end

    def posture_signature_current?
      expected = authorization.evidence.to_h["posture_signature"]
      expected.present? && expected == DelegatedActionAdmission.posture_signature_for(
        project: authorization.project, action: authorization.action
      )
    end

    def policy_permits?
      policy = EffectivePolicy.call(
        project: authorization.project,
        phase: DelegatedActionAdmission::ACTION_PHASES.fetch(authorization.action),
        work_item: authorization.issue,
        trigger: :automatic,
        delegated_action: authorization.action
      )
      policy.present? && policy.permitted?
    end

    # Legacy admissions predate lineage pinning and govern only their
    # identified work item, so only a pinned lineage is re-verified.
    def lineage_current?
      pinned = authorization.pinned_lineage
      return true if pinned.empty?

      DelegatedActionAdmission.lineage_issue_ids(authorization.issue) == pinned
    end
  end
end
