# frozen_string_literal: true

module Inbox
  # Records the operator's assessment-only Inbox choice. Repair and canonical
  # clarification persistence remain separately authorized operations.
  # @spec LAYERED-VERIFY-015 LAYERED-VERIFY-016
  class DecideLayeredVerificationFinding
    ACTIONS = %w[request_repair approve_clarification defer].freeze

    class StaleRevisionError < StandardError; end

    def self.call(...) = new(...).call

    def initialize(finding:, user:, action:, reason:, external_revision:)
      @finding = finding
      @user = user
      @action = action.to_s
      @reason = reason.to_s
      @external_revision = external_revision.to_s
    end

    def call
      raise ArgumentError, "select a valid decision" unless ACTIONS.include?(action)
      raise ArgumentError, "decision reason is required" if reason.blank?

      finding.with_lock do
        raise StaleRevisionError, "The obligation source changed; review fresh evidence before deciding." if stale?

        finding.update!(status: action == "defer" ? "deferred" : "open", decision: recorded_decision)
      end
      finding
    end

    private

    attr_reader :action, :external_revision, :finding, :reason, :user

    def stale?
      finding.obligation.external_revision.to_s != external_revision
    end

    def recorded_decision
      finding.decision.merge(
        "selected_action" => action, "reason" => reason, "decided_by_id" => user.id,
        "decided_at" => Time.current.iso8601, "external_revision" => external_revision
      )
    end
  end
end
