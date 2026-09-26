# frozen_string_literal: true

module AppleVerificationAttempts
  # Advances fair queued attempts through validation, capacity admission, and
  # VM provisioning. GoodJob serializes invocations; the row lock makes a
  # manual or retried invocation safe as well.
  # @spec APPLE-ATTEMPT-001
  # @spec APPLE-ATTEMPT-003
  # @spec APPLE-ATTEMPT-005
  class Dispatcher
    Result = Data.define(:started, :rejected, :skipped)

    def self.call(capacity_sampler: HostCapacity.from_environment, lifecycle: AppleVerification::Lifecycle.from_environment, complete: Complete)
      new(capacity_sampler:, lifecycle:, complete:).call
    end

    def initialize(capacity_sampler:, lifecycle:, complete:)
      @capacity_sampler = capacity_sampler
      @lifecycle = lifecycle
      @complete = complete
    end

    def call
      return Result.new(started: 0, rejected: 0, skipped: true) unless capacity_sampler && lifecycle

      dispatch_queue
    end

    private

    attr_reader :capacity_sampler, :lifecycle, :complete

    def dispatch_queue
      started = 0
      rejected = 0

      Queue.ordered.each do |attempt|
        outcome = dispatch(attempt)
        started += 1 if outcome == :started
        rejected += 1 if outcome == :rejected
        break if outcome.in?(%i[started blocked])
      end

      Result.new(started:, rejected:, skipped: started.zero? && rejected.zero?)
    end

    def dispatch(attempt)
      attempt.with_lock do
        return :stale unless queue_head?(attempt)
        return :rejected unless Validate.call(attempt:).valid

        snapshot = capacity_sampler.call(attempt:)
        return :blocked unless snapshot
        return :blocked unless admitted?(attempt, snapshot)

        provision(attempt)
      end
    end

    def queue_head?(attempt)
      attempt.status == "queued" && Queue.ordered.first&.id == attempt.id
    end

    def admitted?(attempt, snapshot)
      Admission.call(
        attempt:,
        capacity: snapshot.capacity,
        active_vms: active_vm_count,
        critical_memory_samples: snapshot.critical_memory_samples
      ).admitted
    end

    def active_vm_count
      AppleVerificationAttempt.where(status: %w[provisioning running]).count
    end

    def provision(attempt)
      attempt.update!(status: "provisioning")
      lifecycle.provision(
        agent_run: attempt.agent_run,
        image_id: attempt.apple_worker_profile.image_digest,
        profile_id: attempt.apple_worker_profile.name,
        request_id: "apple-verification-attempt:#{attempt.id}",
        apple_verification_attempt: attempt
      )
      WorkerHealth.record_success!(profile: attempt.apple_worker_profile)
      attempt.update!(status: "running", started_at: Time.current)
      :started
    rescue AppleVerification::HostService::AuthenticationError,
      AppleVerification::HostService::UnsupportedRequestError,
      Faraday::Error => error
      WorkerHealth.record_failure!(profile: attempt.apple_worker_profile, reason: error.class.name)
      return :rejected if attempt.reload.terminal?

      complete.call(attempt:, outcome: "unavailable", failure_classification: "worker_infrastructure", lifecycle:)
      :rejected
    end
  end
end
