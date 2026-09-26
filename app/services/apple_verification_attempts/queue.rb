# frozen_string_literal: true

module AppleVerificationAttempts
  # Fair, persisted round-robin queue across account and project heads.
  # @spec APPLE-ATTEMPT-003
  class Queue
    def self.call(...)
      new(...).call
    end

    def initialize(configuration: Configuration.new, clock: Time)
      @configuration = configuration
      @clock = clock
    end

    def call(attempt:)
      enqueue(attempt)
    end

    def enqueue(attempt)
      attempt.with_lock do
        return attempt unless attempt.status == "queued"

        enforce_limits!(attempt)
        attempt.update!(queue_entered_at: attempt.queue_entered_at || clock.current)
      end
      attempt
    end

    def cancel(attempt)
      attempt.with_lock do
        return attempt if attempt.terminal?

        attempt.update!(status: "cancelled", failure_classification: "cancellation_or_timeout", finished_at: clock.current)
      end
      attempt
    end

    def next
      ordered_attempts.first
    end

    def position(attempt)
      return nil unless attempt.status == "queued"

      ordered_attempts.index { |candidate| candidate.id == attempt.id }.to_i + 1
    end

    private

    attr_reader :configuration, :clock

    def ordered_attempts
      remaining = AppleVerificationAttempt.where(status: "queued").order(:queue_entered_at, :id).to_a
      ordered = []
      until remaining.empty?
        fair_account_order(remaining).each { |account_id| ordered << shift_fair_head(remaining, account_id) }
      end
      ordered
    end

    def enforce_limits!(attempt)
      raise ArgumentError, "Apple verification queue is full" if AppleVerificationAttempt.where(status: "queued").count >= configuration.maximum_queue_depth
      return unless attempt.agent_run_id

      attempts = AppleVerificationAttempt.where(agent_run_id: attempt.agent_run_id).where.not(id: attempt.id).count
      raise ArgumentError, "Apple verification attempt limit reached for agent run" if attempts >= configuration.maximum_attempts_per_run
    end

    def fair_account_order(remaining)
      remaining.group_by(&:account_id).values.map(&:first)
        .sort_by { |candidate| [ candidate.queue_entered_at || candidate.created_at, candidate.id ] }
        .map(&:account_id)
    end

    def shift_fair_head(remaining, account_id)
      project_heads = remaining.select { |candidate| candidate.account_id == account_id }.group_by(&:project_id).values.map(&:first)
      next_attempt = project_heads.min_by { |candidate| [ candidate.queue_entered_at || candidate.created_at, candidate.id ] }
      remaining.delete(next_attempt)
      next_attempt
    end
  end
end
