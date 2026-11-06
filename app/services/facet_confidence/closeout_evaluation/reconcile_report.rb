# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Attaches a frozen, retained evaluation report to only the current typed
    # prerequisite occurrences that it assessed. The report is human evidence,
    # not an attestation of whole-issue delivery or policy enforcement.
    # @spec FACET-CONFIDENCE-023
    # @spec PARTIAL-CLOSEOUT-042
    class ReconcileReport
      RELEASED_BY = "facet_confidence_evaluation"
      Result = Data.define(:reconciled, :stale, :notification_ids)

      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        return Result.new(reconciled: 0, stale: 0, notification_ids: []) unless report_ready?

        outcomes = notifications.filter_map { |notification| reconcile(notification) }
        Result.new(reconciled: outcomes.sum { _1.fetch(:reconciled) }, stale: outcomes.sum { _1.fetch(:stale) },
          notification_ids: outcomes.filter_map { _1[:notification_id] })
      end

      private

      attr_reader :evaluation

      def report_ready? = evaluation.frozen? && evaluation.report.present? && evaluation.source_revision.present?

      def notifications
        Notification.active.where(account: evaluation.project.account, subject: evaluation.issue,
          source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE).order(:id)
      end

      def reconcile(notification)
        notification.with_lock do
          notification.reload
          return unless typed_notification?(notification)

          outcomes = applicable_occurrences(notification).map { |occurrence| record(notification, occurrence) }
          resolve_if_complete(notification)
          { notification_id: notification.id, reconciled: outcomes.count(:sufficient), stale: outcomes.count(:stale) }
        end
      end

      def typed_notification?(notification)
        notification.active? && notification.metadata["workflow"] == InboxEscalation::WORKFLOW
      end

      def applicable_occurrences(notification)
        PartialCloseouts::PrerequisiteOccurrences.for(notification).select do |occurrence|
          occurrence["workflow"] == InboxEscalation::WORKFLOW && occurrence["source_issue_number"].to_i == evaluation.issue.github_number
        end
      end

      def record(notification, occurrence)
        current = current_revision?(notification, occurrence)
        outcome = current ? "sufficient" : "stale"
        submission = submission_for(occurrence, outcome)
        update_submission(notification, submission)
        outcome.to_sym
      end

      def current_revision?(notification, occurrence)
        occurrence["source_revision"] == evaluation.source_revision &&
          PartialCloseouts::PrerequisiteOccurrences.current_source_revision(notification, occurrence) == evaluation.source_revision
      end

      def submission_for(occurrence, outcome)
        { "submission_id" => "facet-confidence-evaluation-#{evaluation.id}-#{occurrence.fetch('identity')}",
          "prerequisite_identity" => occurrence.fetch("identity"), "evidence_type" => "facet_confidence_evaluation",
          "evaluation_id" => evaluation.id, "report_digest" => Digest::SHA256.hexdigest(evaluation.report_markdown.to_s),
          "actor_id" => evaluation.created_by_id, "submitted_at" => evaluation.labels_frozen_at.iso8601,
          "validated_at" => Time.current.iso8601, "source_revision" => occurrence["source_revision"], "outcome" => outcome,
          "reason" => reason_for(outcome) }
      end

      def reason_for(outcome)
        return "The closeout evidence changed after this evaluation; start a new evaluation for the current revision." if outcome == "stale"

        "Frozen facet-confidence evaluation report recorded for this prerequisite occurrence."
      end

      def update_submission(notification, submission)
        submissions = Array(notification.metadata["evidence_submissions"])
        existing = submissions.index { |item| item["submission_id"] == submission["submission_id"] }
        submissions[existing] = submission if existing
        submissions << submission unless existing
        notification.update!(metadata: notification.metadata.merge("evidence_submissions" => submissions))
      end

      def resolve_if_complete(notification)
        occurrences = PartialCloseouts::PrerequisiteOccurrences.for(notification)
        return if occurrences.empty? || occurrences.any? { |occurrence| !sufficient_current_submission?(notification, occurrence) }

        notification.update!(resolved_at: Time.current,
          metadata: notification.metadata.merge("released_by" => RELEASED_BY, "released_at" => Time.current.iso8601))
      end

      def sufficient_current_submission?(notification, occurrence)
        submission = Array(notification.metadata["evidence_submissions"]).reverse.find do |item|
          item["prerequisite_identity"] == occurrence["identity"]
        end
        submission&.fetch("outcome", nil) == "sufficient" &&
          submission["source_revision"] == occurrence["source_revision"] && current_revision?(notification, occurrence)
      end
    end
  end
end
