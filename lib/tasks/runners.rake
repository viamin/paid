# frozen_string_literal: true

namespace :runners do
  desc <<~DESC
    Reset accumulated back-off after a runner outage so failed/parked work
    becomes eligible again immediately. Resets three things:
      1. Open/half-open runner circuit breakers (and lingering rate limits).
      2. rate_limited agent runs — makes them due now and clears the requeue/skip
         counters so StaleRunDetectorJob re-queues them on its next tick.
      3. Parked Issues::ReenqueueEligibleJob jobs whose exponential
         (n**4) auto-pick delay has pushed them far into the future.
    Idempotent. Defaults to a dry run; set DRY_RUN=false to apply.
  DESC
  task reset_backoff: :environment do
    dry_run = ENV.fetch("DRY_RUN", "true") != "false"
    now = Time.current

    TenantContext.with_system_access do
      # 1. Runner circuit breakers --------------------------------------------
      circuits = RunnerState.where(circuit_state: %w[open half_open])
        .or(RunnerState.where.not(rate_limited_until: nil))
      circuit_count = circuits.count

      # 2. Rate-limited agent runs --------------------------------------------
      rate_limited = AgentRun.rate_limited
      rate_limited_count = rate_limited.count

      # 3. Parked auto-pick re-enqueue jobs -----------------------------------
      parked_jobs = GoodJob::Job
        .where(finished_at: nil, job_class: "Issues::ReenqueueEligibleJob")
        .where(scheduled_at: now..)
      parked_count = parked_jobs.count

      puts "runners:reset_backoff (#{dry_run ? 'DRY RUN' : 'APPLYING'})"
      puts "  runner circuits open/rate-limited : #{circuit_count}"
      puts "  rate_limited agent runs           : #{rate_limited_count}"
      puts "  parked re-enqueue jobs            : #{parked_count}"

      if dry_run
        puts "No changes written. Re-run with DRY_RUN=false to apply."
        next
      end

      circuits.find_each { |state| state.record_success!(force_close: true) }

      # Make parked rate-limited runs due now without exhausting their budget.
      rate_limited.update_all(
        rate_limited_until: 1.minute.ago,
        stale_requeue_count: 0,
        stale_skip_count: 0,
        updated_at: now
      )

      # Release the exponential auto-pick delay so GoodJob runs them now.
      parked_jobs.update_all(scheduled_at: now)

      Rails.logger.info(
        message: "runners.reset_backoff",
        circuits_reset: circuit_count,
        rate_limited_runs_reset: rate_limited_count,
        reenqueue_jobs_released: parked_count
      )

      puts "Done. Reset #{circuit_count} circuits, #{rate_limited_count} rate-limited runs, " \
        "released #{parked_count} re-enqueue jobs."
    end
  end
end
