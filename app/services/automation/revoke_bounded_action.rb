# frozen_string_literal: true

module Automation
  # Revocation write boundary for bounded delegated actions. Withdrawing an
  # authorization is as authoritative as granting it, so the same
  # action-specific project policy applies: review and repair revocation
  # follows the run permission, while revoking a merge delegation stays
  # reserved to project automation owners.
  # @spec BOUNDED-PHASE-AUTHORIZATION-011
  class RevokeBoundedAction
    class Error < StandardError; end
    class PermissionDenied < Error; end

    def self.call(...)
      new(...).call
    end

    def initialize(authorization:, user:)
      @authorization = authorization
      @user = user
    end

    def call
      ensure_permission!

      authorization.revoke!(user:)
    end

    private

    attr_reader :authorization, :user

    def ensure_permission!
      policy = ProjectPolicy.new(user, authorization.project)
      return if policy.delegate_bounded_action?(authorization.action)

      raise PermissionDenied, "You do not have permission to revoke the #{authorization.action} delegation for this project."
    end
  end
end
