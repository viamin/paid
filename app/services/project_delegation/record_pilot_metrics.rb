# frozen_string_literal: true

module ProjectDelegation
  # Persists one revision-aware pilot-metric snapshot for an enrollment.
  # Snapshots are the durable RDR-080 evidence: the daily sweep appends
  # cumulative `bounded_delivery` windows, and enrollment captures the
  # project's own `conservative_baseline`. Recording is idempotent per
  # enrollment, posture, and window end.
  #
  # @spec PROJECT-DELEGATION-007
  class RecordPilotMetrics
    POSTURES = DelegationPilotMetricSnapshot::POSTURES

    def self.call(enrollment:, posture:, window_started_at:, window_ended_at:)
      enrollment.snapshots.find_or_create_by!(
        posture: posture.to_s,
        window_ended_at: window_ended_at
      ) do |snapshot|
        result = PilotMetrics.call(
          project: enrollment.project,
          window_started_at: window_started_at,
          window_ended_at: window_ended_at
        )
        snapshot.account = enrollment.account
        snapshot.project = enrollment.project
        snapshot.window_started_at = window_started_at
        snapshot.metrics = result.to_h
          .except(:window_started_at, :window_ended_at, :exclusions, :revisions)
          .transform_keys(&:to_s)
        snapshot.exclusions = result.exclusions
        snapshot.revisions = result.revisions
      end
    end
  end
end
