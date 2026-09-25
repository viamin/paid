# frozen_string_literal: true

# One active (non-terminal) Apple verification attempt per agent run. The
# agent-facing quota check in AppleVerification::AgentTools#ensure_quota is
# check-then-create; this partial unique index makes the invariant mechanical
# so two concurrent dispatches cannot both provision verification workers.
class AddOneActiveAppleAttemptPerRunToAppleVerificationAttempts < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    return if index_exists?(:apple_verification_attempts, name: "idx_apple_attempts_one_active_per_run")

    add_index :apple_verification_attempts, :agent_run_id,
      unique: true,
      where: "agent_run_id IS NOT NULL AND status NOT IN ('succeeded', 'failed', 'cancelled', 'timed_out', 'unavailable')",
      name: "idx_apple_attempts_one_active_per_run",
      algorithm: :concurrently
  end

  def down
    return unless index_exists?(:apple_verification_attempts, name: "idx_apple_attempts_one_active_per_run")

    remove_index :apple_verification_attempts, name: "idx_apple_attempts_one_active_per_run", algorithm: :concurrently
  end
end
