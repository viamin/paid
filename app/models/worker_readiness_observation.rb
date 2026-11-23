# frozen_string_literal: true

# Durable, system-wide readiness observations that Temporal worker processes
# publish about themselves while serving their queues. Each worker process is
# the sole writer of its boot-identity row; trusted measurements read the rows
# from any role's container through the shared application database. System
# operational metadata only — including the full boot-time deployment identity —
# and not tenant-owned, so the table carries no tenant columns or
# RLS policy (same boundary as the PgHero history tables); it never holds
# secrets, process arguments, or environment contents.
# @spec TRUSTED-MEASUREMENTS-008 DEVELOPMENT-ENVIRONMENT-UPDATE-005
class WorkerReadinessObservation < ApplicationRecord
  ROLES = %w[poll agent].freeze

  validates :role, presence: true, inclusion: { in: ROLES }
  validates :environment, presence: true
  validates :pid, numericality: { only_integer: true, greater_than: 0 }
  validates :ready_at, presence: true
  validates :heartbeat_at, presence: true

  # Publishes one liveness beat for a worker boot. Rolling deploys intentionally
  # overlap instances of a role, so environment, PID, and ready_at preserve
  # every identity without crossing deployment scopes.
  def self.record!(role:, pid:, ready_at:, revision:, deployment_revision:, heartbeat_at:, environment:)
    role = role.to_s
    environment = environment.to_s
    raise ArgumentError, "unsupported Temporal worker role" unless ROLES.include?(role)
    raise ArgumentError, "worker pid must be positive" unless pid.to_i.positive?
    raise ArgumentError, "worker environment must be present" if environment.empty?

    now = Time.current
    upsert_all(
      [ { environment:, role:, pid: pid.to_i, ready_at:, revision:, deployment_revision:, heartbeat_at:,
          created_at: now, updated_at: now } ],
      unique_by: %i[environment role pid ready_at], record_timestamps: false,
      update_only: %i[heartbeat_at updated_at]
    )
  end

  # All published boot identities for a role in one environment. Readers decide
  # which observations remain live from their heartbeats; stale rows retain
  # restart history.
  def self.for_role(role, environment:)
    role = role.to_s
    raise ArgumentError, "unsupported Temporal worker role" unless ROLES.include?(role)

    where(role:, environment: environment.to_s).order(:ready_at, :id)
  end
end
