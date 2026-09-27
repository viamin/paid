# frozen_string_literal: true

module AppleVerificationAttempts
  # Provider-neutral host capacity values measured by the trusted host service.
  # @spec APPLE-ATTEMPT-001
  CapacitySnapshot = Data.define(
    :free_host_disk_bytes,
    :free_memory_fraction,
    :free_guest_disk_bytes,
    :critical_memory_pressure
  )
end
