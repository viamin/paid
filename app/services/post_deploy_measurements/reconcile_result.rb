# frozen_string_literal: true

module PostDeployMeasurements
  # Feeds a current, passing measurement into the existing criterion/evidence
  # path: records machine-collected sufficient evidence for exactly the bound
  # prerequisite occurrence on the existing partial-closeout prerequisite
  # notification, and resolves that notification only when every occurrence
  # it carries is satisfied — releasing with a marker the existing
  # re-enqueue and Inbox-refresh hooks observe. A passing measurement never
  # attests whole-issue completion and never releases an unbound,
  # superseded, or foreign occurrence.
  # @spec POST-DEPLOY-006 @spec POST-DEPLOY-008
  class ReconcileResult
    Result = Data.define(:measurement, :released, :reason)

    def self.call(...) = new(...).call

    def initialize(measurement)
      @measurement = measurement
    end

    def call
      return result(false, "measurement did not pass") unless measurement.passed?
      return result(false, "measurement is not bound to a prerequisite") if measurement.prerequisite_identity.blank?
      return result(false, "prerequisite was already released") if measurement.released?
      return result(false, "no active prerequisite notification for this issue") unless notification

      notification.with_lock do
        notification.reload
        return result(false, "prerequisite notification is no longer active") unless notification.active?
        return result(false, "bound occurrence is not on the notification anymore") unless occurrence

        record_machine_evidence!
        release_if_complete!
      end
      result(released?, release_reason)
    end

    private

    attr_reader :measurement

    def result(released, reason)
      Result.new(measurement: measurement, released: released, reason: reason)
    end

    def notification
      @notification ||= Notification.find_by(
        account: measurement.account,
        subject: measurement.issue,
        source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
        resolved_at: nil,
        dismissed_at: nil
      )
    end

    def occurrence
      @occurrence ||= occurrences.find { |candidate| candidate["identity"] == measurement.prerequisite_identity }
    end

    def occurrences
      @occurrences ||= PartialCloseouts::PrerequisiteOccurrences.for(notification)
    end

    # Idempotent under duplicate events: an earlier submission from this
    # measurement is replaced, not appended, and the recorded revision binds
    # the evidence to the occurrence generation it measured. When the
    # occurrence's source revision has moved since it was recorded, the
    # evidence is recorded as stale — never sufficient — so a superseded
    # occurrence keeps its gate (same discipline as ReconcileEvidence).
    def record_machine_evidence!
      submissions = Array(notification.metadata["evidence_submissions"]).reject do |submission|
        submission["post_deploy_measurement_id"] == measurement.id
      end
      submissions << machine_submission
      notification.update!(metadata: notification.metadata.merge("evidence_submissions" => submissions))
    end

    def machine_submission
      entry = {
        "prerequisite_identity" => measurement.prerequisite_identity,
        "evidence_url" => nil,
        "explanation" => "Trusted post-deploy check #{measurement.check_key} v#{measurement.check_version}: " \
                         "#{measurement.counts.fetch('actionable_closed_source')} actionable against target " \
                         "#{measurement.details.dig('comparison', 'target')}; deployment " \
                         "#{measurement.deployed_revision}.",
        "source_revision" => occurrence.fetch("source_revision", nil),
        "validator_id" => nil,
        "post_deploy_measurement_id" => measurement.id,
        "validated_at" => Time.current.iso8601
      }
      if occurrence_revision_current?
        entry.merge("outcome" => "sufficient",
          "reason" => "Machine-collected post-deploy measurement satisfied this prerequisite.")
      else
        entry.merge("outcome" => "stale",
          "reason" => "The closeout evidence changed; the measurement was taken against a prior prerequisite revision.")
      end
    end

    # Mirrors PartialCloseouts::ReconcileEvidence#source_revision_current?:
    # a recorded revision only stays current while it equals the live source
    # revision of the occurrence's source issue.
    def occurrence_revision_current?
      expected = occurrence.fetch("source_revision", nil)
      return true if expected.blank?

      expected == PartialCloseouts::PrerequisiteOccurrences.current_source_revision(notification, occurrence)
    end

    def release_if_complete!
      return unless all_occurrences_satisfied?

      notification.update!(
        resolved_at: Time.current,
        metadata: notification.metadata.merge(
          "released_by" => "post_deploy_measurement",
          "released_at" => Time.current.iso8601
        )
      )
      measurement.update!(released_at: Time.current)
    end

    def released?
      measurement.released?
    end

    def release_reason
      released? ? "notification resolved; all occurrences satisfied" : "other occurrences still require evidence"
    end

    # Mirrors PartialCloseouts::ReconcileEvidence#all_occurrences_sufficient?:
    # the latest current-revision submission for every occurrence must be
    # sufficient, so a foreign or stale occurrence keeps its gate.
    def all_occurrences_satisfied?
      occurrences.present? && occurrences.all? do |candidate|
        latest_submission_for(candidate)&.fetch("outcome", nil) == "sufficient"
      end
    end

    def latest_submission_for(candidate)
      Array(notification.metadata["evidence_submissions"]).reverse.find do |submission|
        submission["prerequisite_identity"] == candidate["identity"] &&
          current_submission?(candidate, submission)
      end
    end

    def current_submission?(candidate, submission)
      candidate["source_revision"].blank? || candidate["source_revision"] == submission["source_revision"]
    end
  end
end
