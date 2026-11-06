# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Submits a frozen local report through the same prerequisite-evidence
    # pipeline as operator-provided artifacts. The report is evidence, not an
    # acceptance attestation: ValidateSubmittedEvidence still assesses its
    # applicability to the exact current prerequisite.
    # @spec FACET-CONFIDENCE-021 PARTIAL-CLOSEOUT-036
    class AttachReportEvidence
      EVIDENCE_KIND = "facet_confidence_evaluation_report"

      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        active_notifications.each { |notification| attach(notification) }
      end

      private

      attr_reader :evaluation

      def active_notifications
        Notification.active.where(
          account: evaluation.project.account,
          subject: evaluation.issue,
          source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE
        ).select { |notification| notification.metadata["workflow"] == InboxEscalation::WORKFLOW }
      end

      def attach(notification)
        PartialCloseouts::PrerequisiteOccurrences.for(notification).each do |occurrence|
          PartialCloseouts::SubmitEvidence.call(
            notification:, actor: evaluation.created_by,
            prerequisite_identity: occurrence.fetch("identity"),
            evidence_url: report_path,
            explanation: "Frozen independent evaluation report ##{evaluation.id}.",
            evidence_kind: EVIDENCE_KIND,
            evidence_id: evaluation.id,
            source_revision: evaluation.source_revision
          )
        end
      end

      def report_path = "/projects/#{evaluation.project_id}/facet_confidence_evaluations/#{evaluation.id}"
    end
  end
end
