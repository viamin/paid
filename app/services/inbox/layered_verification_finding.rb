# frozen_string_literal: true

module Inbox
  # Read-only finding presentation. Conversation and deferral preserve rather
  # than resolve the discrepancy or authorize repair.
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016
  class LayeredVerificationFinding
    def self.call(finding) = new(finding).call

    def initialize(finding)
      @finding = finding
    end

    def call
      Snapshot.new(finding) unless finding.resolved?
    end

    class Snapshot
      def initialize(finding) = @finding = finding
      def summary = finding.summary.presence || "Verification evidence needs a decision."
      def waiting_since = finding.created_at
      def resolved? = finding.resolved?

      def detail
        {
          scope: finding.obligation.scope_description,
          source_reference: finding.obligation.external_identity,
          source_passages: finding.source_passages,
          observed_behavior: finding.observed_behavior,
          check_limitations: finding.check_limitations,
          question: finding.question,
          options: finding.options,
          consequences: "Deferral and chat preserve this discrepancy; they do not approve intent or start repair.",
          audit_run_id: finding.agent_run_id,
          intent_revision: finding.obligation.external_revision
        }
      end

      private

      attr_reader :finding
    end

    private

    attr_reader :finding
  end
end
