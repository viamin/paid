# frozen_string_literal: true

module Inbox
  class LayeredVerificationFinding
    # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016
    def self.call(finding) = new(finding).call

    def initialize(finding)
      @finding = finding
    end

    def call
      return unless finding.unresolved?

      Snapshot.new(finding:)
    end

    class Snapshot
      attr_reader :finding

      def initialize(finding:)
        @finding = finding
      end

      delegate :project, to: :finding
      def summary = finding.decision_question
      def waiting_since = finding.created_at
      def details
        {
          scope: finding.obligation.scope_description, source_reference: finding.obligation.external_identity,
          source_passages: finding.source_passages, observed_behavior: finding.observed_behavior,
          limitations: finding.check_limitations, question: finding.decision_question,
          options: finding.options, observations: finding.observations,
          audit_run_id: finding.originating_audit_run_id, external_revision: finding.obligation.external_revision,
          pending_persistence: finding.obligation.approval_state != "approved"
        }
      end
    end

    def self.open_for(project_ids)
      ::LayeredVerificationFinding.includes(:project, :obligation).where(project_id: project_ids, status: %w[open deferred])
    end

    private

    attr_reader :finding
  end
end
