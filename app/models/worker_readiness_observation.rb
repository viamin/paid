# frozen_string_literal: true

# Durable, system-wide readiness observations that Temporal worker processes
# publish about themselves while serving their queues. Each owning role is the
# sole writer of its row; trusted measurements read the rows from any role's
# container through the shared application database. System operational
# metadata only — not tenant-owned, so the table carries no tenant columns or
# RLS policy (same boundary as the PgHero history tables); it never holds
# secrets, process arguments, or environment contents.
# @spec TRUSTED-MEASUREMENTS-008 DEVELOPMENT-ENVIRONMENT-UPDATE-004
class WorkerReadinessObservation < ApplicationRecord
  ROLES = %w[poll agent].freeze

  validates :role, presence: true, inclusion: { in: ROLES }
  validates :pid, numericality: { only_integer: true, greater_than: 0 }
  validates :ready_at, presence: true
  validates :heartbeat_at, presence: true

  # Publishes one liveness beat for a role: an atomic upsert keyed by role so
  # a restarted worker replaces its own earlier boot identity and concurrent
  # role replicas cannot create duplicate rows.
  def self.record!(role:, pid:, ready_at:, revision:, heartbeat_at:)
    role = role.to_s
    raise ArgumentError, "unsupported Temporal worker role" unless ROLES.include?(role)
    raise ArgumentError, "worker pid must be positive" unless pid.to_i.positive?

    now = Time.current
    upsert_all(
      [ { role:, pid: pid.to_i, ready_at:, revision:, heartbeat_at:, created_at: now, updated_at: now } ],
      unique_by: :role, record_timestamps: false,
      update_only: %i[pid ready_at revision heartbeat_at updated_at]
    )
  end

  # The latest published observation for a role. Reader contract mirrors the
  # writer: only the two fixed Temporal roles exist.
  def self.for_role(role)
    role = role.to_s
    raise ArgumentError, "unsupported Temporal worker role" unless ROLES.include?(role)

    find_by(role:)
  end
end
