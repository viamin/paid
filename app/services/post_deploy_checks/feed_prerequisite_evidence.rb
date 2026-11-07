# frozen_string_literal: true

module PostDeployChecks
  # Bridges a succeeded trusted measurement into the existing partial-closeout
  # prerequisite release path (PartialCloseouts::SubmitEvidence /
  # ValidateSubmittedEvidence) by writing the same evidence_submissions shape
  # under a new "trusted_measurement" released_by value. A current passing
  # measurement releases only the one prerequisite occurrence it names — it
  # never resolves a notification whose other occurrences are not already
  # sufficient, and a target miss records inspectable evidence without
  # resolving anything.
  # @spec POST-DEPLOY-CHECK-007 POST-DEPLOY-CHECK-008
  class FeedPrerequisiteEvidence
    RELEASED_BY = "trusted_measurement"

    def self.call(...) = new(...).call

    def initialize(run:, notification:, prerequisite_identity:)
      @run = run
      @notification = notification
      @prerequisite_identity = prerequisite_identity.to_s
    end

    def call
      return unless run.succeeded?

      notification.with_lock do
        occurrence = current_occurrence
        next nil unless occurrence

        existing = latest_submission_for(occurrence)
        next existing if existing && existing["post_deploy_check_run_id"] == run.id
        next nil unless current_revision?(occurrence)

        record_submission!(occurrence)
      end
    end

    private

    attr_reader :run, :notification, :prerequisite_identity

    def current_occurrence
      PartialCloseouts::PrerequisiteOccurrences.for(notification).find { |item| item["identity"] == prerequisite_identity }
    end

    def latest_submission_for(occurrence)
      Array(notification.metadata["evidence_submissions"]).reverse.find { |item| item["prerequisite_identity"] == occurrence["identity"] }
    end

    def current_revision?(occurrence)
      expected = occurrence["source_revision"]
      expected.blank? || expected == PartialCloseouts::PrerequisiteOccurrences.current_source_revision(notification, occurrence)
    end

    def check_result
      @check_result ||= Registry.fetch(run.check_key)::Result.new(**run.result.symbolize_keys)
    end

    def outcome
      check_result.met_target? ? "sufficient" : "insufficient"
    end

    def reason
      "Trusted post-deploy measurement for #{run.project.full_name} found #{summary}, " \
        "#{check_result.met_target? ? 'meeting' : 'not yet meeting'} the target."
    end

    def summary
      check_result.to_h.except(:scope).map { |key, value| "#{key}=#{value}" }.join(", ")
    end

    def record_submission!(occurrence)
      entry = {
        "submission_id" => SecureRandom.uuid, "prerequisite_identity" => prerequisite_identity,
        "evidence_url" => nil, "explanation" => reason, "actor_id" => nil,
        "submitted_at" => Time.current.iso8601, "source_revision" => occurrence["source_revision"],
        "outcome" => outcome, "reason" => reason, "post_deploy_check_run_id" => run.id,
        "deployed_revision" => run.deployed_revision
      }
      submissions = Array(notification.metadata["evidence_submissions"]) + [ entry ]
      attributes = { metadata: notification.metadata.merge("evidence_submissions" => submissions) }

      if outcome == "sufficient" && all_current_occurrences_sufficient?(submissions)
        released_at = Time.current
        attributes[:resolved_at] = released_at
        attributes[:metadata] = attributes[:metadata].merge("released_by" => RELEASED_BY, "released_at" => released_at.iso8601)
      end

      notification.update!(attributes)
      entry
    end

    def all_current_occurrences_sufficient?(submissions)
      PartialCloseouts::PrerequisiteOccurrences.for(notification).all? do |occurrence|
        submission = submissions.reverse.find { |item| item["prerequisite_identity"] == occurrence["identity"] }
        submission&.fetch("outcome", nil) == "sufficient" && submission["source_revision"] == occurrence["source_revision"]
      end
    end
  end
end
