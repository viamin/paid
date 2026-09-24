# frozen_string_literal: true

module AppleVerificationAttempts
  # Host-side capacity probe used by {AppleVerificationAttempts::Admission}
  # to decide whether to admit a new Apple verification attempt. The probe
  # is intentionally small and query-only: it never asks the macOS worker to
  # run anything, and it never inspects the macOS guest. It pulls the active
  # Apple VM count from the database (a provisioning or running attempt owns
  # the single worker slot) and reads host-level memory and disk from the
  # configured macOS host service. Tests may inject a provider directly
  # without needing a host-service transport.
  # @spec APPLE-ATTEMPT-001
  class HostCapacity
    # Returns a Hash with at least these keys:
    #   :active_apple_vms         Integer count of provisioning/running attempts
    #   :disk_free_gib            Float free host disk in GiB (nil when unknown)
    #   :memory_free_percent      Float free host memory as a percent (nil when unknown)
    #   :guest_disk_free_gib      Float free disk inside the booted guest in GiB (nil when unknown)
    #   :memory_pressure_window   Array<Float> recent memory_free_percent samples, oldest first
    Snapshot = Data.define(:active_apple_vms, :disk_free_gib, :memory_free_percent,
      :guest_disk_free_gib, :memory_pressure_window)

    def self.default
      new
    end

    def initialize(
      host_metrics_provider: nil,
      attempt_scope: AppleVerificationAttempt,
      clock: Time
    )
      @host_metrics_provider = host_metrics_provider || default_host_metrics_provider
      @attempt_scope = attempt_scope
      @clock = clock
    end

    def snapshot
      active_vms = active_apple_vms
      host_metrics = @host_metrics_provider.call
      Snapshot.new(
        active_apple_vms: active_vms,
        disk_free_gib: host_metrics[:disk_free_gib],
        memory_free_percent: host_metrics[:memory_free_percent],
        guest_disk_free_gib: host_metrics[:guest_disk_free_gib],
        memory_pressure_window: Array(host_metrics[:memory_pressure_window])
      )
    end

    private

    attr_reader :attempt_scope, :clock

    def active_apple_vms
      attempt_scope.active.count
    end

    def default_host_metrics_provider
      endpoint = ENV["APPLE_VERIFICATION_HOST_URL"]
      token = ENV["APPLE_VERIFICATION_HOST_TOKEN"]
      return -> { unknown_metrics } if endpoint.blank? || token.blank?

      host = AppleVerification::HostClient.new(endpoint: endpoint)
      -> { metrics_from(host.call(version: AppleVerification::HostService::API_VERSION, operation: "readiness", payload: {}, token: token)) }
    end

    def metrics_from(readiness)
      payload = readiness.deep_stringify_keys
      disk = payload.fetch("disk", {})
      memory = payload.fetch("memory", {})

      {
        disk_free_gib: disk["free_gib"],
        memory_free_percent: memory["free_percent"],
        guest_disk_free_gib: disk["guest_free_gib"] || disk["free_gib"],
        memory_pressure_window: memory["pressure_window"] || []
      }
    end

    def unknown_metrics
      { disk_free_gib: nil, memory_free_percent: nil, guest_disk_free_gib: nil, memory_pressure_window: [] }
    end
  end
end
