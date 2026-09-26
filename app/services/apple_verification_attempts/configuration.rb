# frozen_string_literal: true

module AppleVerificationAttempts
  # Operator-controlled limits for Apple verification admission and cleanup.
  # @spec APPLE-ATTEMPT-001
  class Configuration
    GIB = 1024**3

    attr_reader :active_vm_limit, :minimum_host_disk_bytes, :minimum_memory_free_fraction,
      :minimum_guest_disk_bytes, :attempt_timeout, :failed_vm_retention,
      :maximum_queue_depth, :maximum_retries, :maximum_attempts_per_run,
      :health_failure_limit

    def initialize(active_vm_limit: self.class.integer_env("APPLE_VERIFICATION_ACTIVE_VM_LIMIT", 1),
      minimum_host_disk_bytes: self.class.integer_env("APPLE_VERIFICATION_MINIMUM_HOST_DISK_GIB", 60) * GIB,
      minimum_memory_free_fraction: self.class.float_env("APPLE_VERIFICATION_MINIMUM_MEMORY_FREE_PERCENT", 25) / 100,
      minimum_guest_disk_bytes: self.class.integer_env("APPLE_VERIFICATION_MINIMUM_GUEST_DISK_GIB", 15) * GIB,
      attempt_timeout: self.class.integer_env("APPLE_VERIFICATION_ATTEMPT_TIMEOUT_MINUTES", 45).minutes,
      failed_vm_retention: self.class.integer_env("APPLE_VERIFICATION_FAILED_VM_RETENTION_MINUTES", 60).minutes,
      maximum_queue_depth: self.class.integer_env("APPLE_VERIFICATION_MAXIMUM_QUEUE_DEPTH", 100),
      maximum_retries: self.class.integer_env("APPLE_VERIFICATION_MAXIMUM_RETRIES", 1),
      maximum_attempts_per_run: self.class.integer_env("APPLE_VERIFICATION_MAXIMUM_ATTEMPTS_PER_RUN", 2),
      health_failure_limit: self.class.integer_env("APPLE_VERIFICATION_HEALTH_FAILURE_LIMIT", 3))
      @active_vm_limit = active_vm_limit
      @minimum_host_disk_bytes = minimum_host_disk_bytes
      @minimum_memory_free_fraction = minimum_memory_free_fraction
      @minimum_guest_disk_bytes = minimum_guest_disk_bytes
      @attempt_timeout = attempt_timeout
      @failed_vm_retention = failed_vm_retention
      @maximum_queue_depth = maximum_queue_depth
      @maximum_retries = maximum_retries
      @maximum_attempts_per_run = maximum_attempts_per_run
      @health_failure_limit = health_failure_limit
    end

    def self.integer_env(name, default)
      Integer(ENV.fetch(name, default.to_s), exception: false) || default
    end

    def self.float_env(name, default)
      Float(ENV.fetch(name, default.to_s), exception: false) || default
    end
  end
end
