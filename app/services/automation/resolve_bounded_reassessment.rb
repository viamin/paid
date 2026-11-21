# frozen_string_literal: true

module Automation
  # The only resolution path for a reassessment pause. Resume changes no
  # pinned evidence and is allowed only after the caller has revalidated it.
  # @spec BOUNDED-PHASE-AUTHORIZATION-005
  class ResolveBoundedReassessment
    class Error < StandardError; end
    class PermissionDenied < Error; end
    class InvalidResolution < Error; end

    def self.call(...) = new(...).call

    def initialize(authorization:, user:, resolution:, revalidated: false)
      @authorization = authorization
      @user = user
      @resolution = resolution.to_sym
      @revalidated = revalidated
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
      authorization.revoke!(user:) || raise(InvalidResolution, "authorization is no longer resolvable")
      :stopped
    end

    def resume
      raise InvalidResolution, "revalidation is required before resuming unchanged scope" unless @revalidated
      raise InvalidResolution, "authorization is no longer resolvable" unless authorization.resume_reassessment!

      Audit::RecordEvent.call(action: "bounded_action.reassessment_resumed", actor: user, subject: authorization,
        metadata: { "action" => authorization.action })
      :resumed
    end
  end
end
