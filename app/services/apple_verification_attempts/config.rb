# frozen_string_literal: true

module AppleVerificationAttempts
  # Centralizes configuration for Apple verification scheduling and VM lifecycle.
  # Values read from APPLE_VERIFICATION_* environment variables, falling back to
  # the defaults below.
  # @spec APPLE-ATTEMPT-001
  # @spec APPLE-ATTEMPT-003
  # @spec APPLE-ATTEMPT-004
  module Config
    DEFAULTS = {
      max_active_vms: 1,
      min_free_host_disk_gib: 60,
      min_free_memory_percent: 25,
      min_free_guest_disk_gib: 15,
      attempt_timeout_minutes: 45,
      max_queue_depth: 100,
      max_retries: 3,
      failed_vm_retention_hours: 1,
      max_attempts_per_run: 3,
      worker_health_failure_threshold: 3,
      critical_memory_percent: 10,
      critical_memory_pressure_samples: 3
    }.freeze

    class << self
      def max_active_vms = fetch(:max_active_vms)
      def min_free_host_disk_gib = fetch(:min_free_host_disk_gib)
      def min_free_memory_percent = fetch(:min_free_memory_percent)
      def min_free_guest_disk_gib = fetch(:min_free_guest_disk_gib)
      def attempt_timeout_minutes = fetch(:attempt_timeout_minutes)
      def max_queue_depth = fetch(:max_queue_depth)
      def max_retries = fetch(:max_retries)
      def failed_vm_retention_hours = fetch(:failed_vm_retention_hours)
      def max_attempts_per_run = fetch(:max_attempts_per_run)
      def worker_health_failure_threshold = fetch(:worker_health_failure_threshold)
      def critical_memory_percent = fetch(:critical_memory_percent)
      def critical_memory_pressure_samples = fetch(:critical_memory_pressure_samples)
    end

    def self.fetch(key)
      value = ENV["APPLE_VERIFICATION_#{key.to_s.upcase}"]
      return Integer(value) if value.present?

      DEFAULTS.fetch(key)
    end
    private_class_method :fetch
  end
end
