# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Session-scoped probe for the ExecuteReviewer advisory execution lock.
    # Recovery and re-enqueue decisions must distinguish "a live worker still
    # holds the execution lock" from "the worker died and its database
    # session released the lock": a stale heartbeat alone would interrupt a
    # genuinely slow provider call. The probe tries the lock on the caller's
    # session; acquiring it proves no other backend holds it (the probe then
    # releases immediately so it never blocks real execution).
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class ExecutionLock
      NAMESPACE = ExecuteReviewer::ADVISORY_LOCK_NAMESPACE
      TRY_LOCK_SQL = "SELECT pg_try_advisory_lock(?, ?)".freeze
      UNLOCK_SQL = "SELECT pg_advisory_unlock(?, ?)".freeze

      class << self
        # True when some OTHER database session currently holds the
        # execution lock for this evaluation.
        def held_by_other_session?(evaluation_id)
          acquired = acquire(evaluation_id)
          return true unless acquired # another backend holds the lock

          release(evaluation_id)
          false
        rescue StandardError => error
          # A failed probe must never green-light a second execution: treat
          # the lock as held so the caller refuses rather than races.
          Rails.logger.warn(
            message: "intent_conformance.shadow_evaluation_lock_probe_failed",
            shadow_evaluation_id: evaluation_id,
            error_class: error.class.name
          )
          true
        end

        private

        def acquire(evaluation_id)
          ActiveRecord::Base.connection.select_value(
            ActiveRecord::Base.sanitize_sql_array([ TRY_LOCK_SQL, NAMESPACE, evaluation_id ])
          )
        end

        def release(evaluation_id)
          ActiveRecord::Base.connection.execute(
            ActiveRecord::Base.sanitize_sql_array([ UNLOCK_SQL, NAMESPACE, evaluation_id ])
          )
        end
      end
    end
  end
end
