# frozen_string_literal: true

module ProjectDelegation
  # Release an explicit hold on delegated work (RDR-080). Releasing is an
  # ownership act like placing one, and it never rewrites the hold: the
  # released record, its reason, and its audit history stay inspectable, so
  # a released hold cannot be confused with a hold that never existed.
  #
  # @spec PROJECT-DELEGATION-010
  class ReleaseHold
    class Error < StandardError; end
    class PermissionDenied < Error; end
    class NotHeld < Error; end

    def self.call(...)
      new(...).call
    end

    def initialize(project:, actor:)
      @project = project
      @actor = actor
    end

    def call
      ensure_authorized!
      ensure_held!

      hold.release!(user: actor)
    end

    private

    attr_reader :project, :actor

    def ensure_authorized!
      return if ProjectPolicy.new(actor, project).manage_delegation_hold?

      raise PermissionDenied, "You do not have permission to release the delegation hold for this project."
    end

    def ensure_held!
      return if hold&.held?

      raise NotHeld, "Delegated work is not on hold for this project."
    end

    def hold
      @hold ||= ProjectDelegationHold.held.where(project:).order(id: :desc).first
    end
  end
end
