# frozen_string_literal: true

require "digest"

module LayeredVerification
  module Findings
    # Revalidates the three facts an Inbox action depends on, immediately
    # before the action is honored: the obligation's revision still matches
    # the repository, the acting user still holds the action's permission, and
    # no equivalent request is already in flight.
    #
    # @spec LAYERED-VERIFY-018
    class Revalidate
      Result = Data.define(:allowed, :reason) do
        def allowed? = allowed
      end

      ACTIONS = {
        "acknowledge" => :manage_issues?,
        "defer" => :manage_issues?,
        "request_rerun" => :manage_issues?,
        "request_repair" => :update?
      }.freeze

      def self.call(...)
        new(...).call
      end

      def initialize(finding:, user:, action:, current_revision: nil, policy: nil)
        @finding = finding
        @user = user
        @action = action.to_s
        @current_revision = current_revision
        @policy = policy
      end

      def call
        return deny("the source has changed since this finding was recorded") if stale_revision?
        return deny("you are no longer authorized to perform this action") unless authorized?
        return deny("an equivalent request for this finding is already in progress") if duplicate_request?

        Result.new(allowed: true, reason: nil)
      end

      private

      attr_reader :action, :current_revision, :finding, :policy, :user

      def deny(reason)
        Result.new(allowed: false, reason: reason)
      end

      def stale_revision?
        return false if finding.external_revision.blank?
        return false if current_revision.blank?

        finding.external_revision != current_revision
      end

      def authorized?
        query = ACTIONS.fetch(action, :manage_issues?)
        policy_instance.public_send(query) == true
      rescue Pundit::NotAuthorizedError
        false
      end

      def policy_instance
        policy || ProjectPolicy.new(user, finding.project)
      end

      def duplicate_request?
        finding.project.layered_verification_audits
          .where(status: %w[planned dispatched running])
          .where(target_revision: finding.external_revision)
          .where.not(agent_run_id: finding.agent_run_id)
          .exists?
      end
    end
  end
end
