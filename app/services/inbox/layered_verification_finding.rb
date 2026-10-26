# frozen_string_literal: true

module Inbox
  # Read model for human-actionable audit discrepancies. It deliberately has no
  # transition methods: chat, acknowledgement, and deferral are not resolution.
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016
  class LayeredVerificationFinding
    def self.call(finding) = new(finding).call

    def initialize(finding)
      @finding = finding
    end

    def call
      return unless finding.status.in?(%w[open deferred])

      Snapshot.new(finding:)
    end

    class Snapshot
      attr_reader :finding

      def initialize(finding:)
        @finding = finding
      end

      delegate :project, :obligation, to: :finding

      def title = "Verification finding: #{obligation.external_identity}"
      def waiting_since = finding.created_at
      def summary = finding.detail.fetch("summary", "Audit evidence contradicts the current obligation.")
      def detail = finding.detail
      def observations = finding.observations.includes(:check_result, :agent_run).order(:created_at)
      def actions = %w[discuss propose_clarification request_repair defer]
    end

    private

    attr_reader :finding
  end
end
