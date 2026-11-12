# frozen_string_literal: true

module ProjectDelegation
  # Place an explicit hold on delegated work for one project (RDR-080). A hold
  # pauses the next delegated action without changing the posture, the
  # admission snapshots, or the delegated evidence, and it is released by an
  # authorized actor rather than by a posture change.
  #
  # @spec PROJECT-DELEGATION-010
  class PlaceHold
    class Error < StandardError; end
    class PermissionDenied < Error; end
    class AlreadyHeld < Error; end
    class MissingReason < Error; end

    def self.call(...)
      new(...).call
    end

    def initialize(project:, actor:, reason:)
      @project = project
      @actor = actor
      @reason = reason.to_s.strip
    end

    def call
      ensure_authorized!
      ensure_reason!
      ensure_not_held!

      hold = nil
      ProjectDelegationHold.transaction do
        hold = ProjectDelegationHold.create!(
          account: project.account,
          project:,
          held_by: actor,
          reason:,
          status: "held",
          held_at: Time.current
        )
        audit(hold)
      end
      RouteAffectedWork.call(
        project:,
        reason: "delegation_hold",
        recovery: "release_hold",
        title: "Delegated work is on hold",
        description: "Delegated work is paused until an authorized actor releases the hold. " \
          "Recovery: release_hold."
      )
      hold
    end

    private

    attr_reader :project, :actor, :reason

    def ensure_authorized!
      return if ProjectPolicy.new(actor, project).manage_delegation_hold?

      raise PermissionDenied, "You do not have permission to hold delegated work for this project."
    end

    def ensure_reason!
      return if reason.present?

      raise MissingReason, "A hold needs a reason so the operator can see why delegated work stopped."
    end

    def ensure_not_held!
      return unless ProjectDelegationHold.held.where(project:).exists?

      raise AlreadyHeld, "Delegated work is already on hold for this project."
    end

    # Immutable audit event: who placed the hold, on which project, and why.
    def audit(hold)
      Audit::RecordEvent.call(
        action: "project_delegation.hold_placed",
        actor: actor,
        subject: hold,
        metadata: {
          "project_id" => project.id,
          "project_name" => project.full_name,
          "reason" => hold.reason,
          "hold_id" => hold.id
        }
      )
    end
  end
end
