# frozen_string_literal: true

module AppleVerificationAttempts
  # @spec APPLE-ATTEMPT-001
  # @spec APPLE-ATTEMPT-002
  # Decides whether an Apple verification attempt may be admitted given the
  # current macOS worker slot, host disk, host memory, and guest disk
  # thresholds. The first deployment supports exactly one active Apple
  # verification VM, so admission requires that slot to be free and that the
  # host retains enough free disk and free memory to clone a clean VM image.
  # Crossing a normal admission threshold stops new work; a running attempt
  # is terminated only for an actual host-safety condition (which lives
  # outside this service — {AppleVerificationAttempts::TimeoutMonitor} and
  # the runtime watcher own that path).
  class Admission
    DEFAULT_MAX_ACTIVE_VMS = 1
    DEFAULT_MIN_HOST_DISK_GIB = 60
    DEFAULT_MIN_HOST_MEMORY_PERCENT = 25
    DEFAULT_MIN_GUEST_DISK_GIB = 15
    DEFAULT_CRITICAL_MEMORY_PERCENT = 10
    DEFAULT_SUSTAINED_CRITICAL_SAMPLES = 3

    Decision = Data.define(:allowed, :reason, :figures, :thresholds) do
      def allowed?
        allowed
      end
    end

    REASONS = %w[
      allowed
      active_vm_limit
      host_disk_low
      host_memory_low
      guest_disk_unknown
      sustained_critical_memory_pressure
      host_safety_violation
    ].freeze

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(
      project:,
      host_capacity: HostCapacity.default,
      max_active_vms: DEFAULT_MAX_ACTIVE_VMS,
      min_host_disk_gib: DEFAULT_MIN_HOST_DISK_GIB,
      min_host_memory_percent: DEFAULT_MIN_HOST_MEMORY_PERCENT,
      min_guest_disk_gib: DEFAULT_MIN_GUEST_DISK_GIB,
      critical_memory_percent: DEFAULT_CRITICAL_MEMORY_PERCENT,
      sustained_critical_samples: DEFAULT_SUSTAINED_CRITICAL_SAMPLES
    )
      @project = project
      @host_capacity = host_capacity
      @max_active_vms = max_active_vms
      @min_host_disk_gib = min_host_disk_gib
      @min_host_memory_percent = min_host_memory_percent
      @min_guest_disk_gib = min_guest_disk_gib
      @critical_memory_percent = critical_memory_percent
      @sustained_critical_samples = sustained_critical_samples
    end

    def call
      figures = host_capacity.snapshot
      thresholds = thresholds_payload

      return deny("active_vm_limit", figures:, thresholds:) if figures.active_apple_vms >= @max_active_vms
      return deny("host_disk_low", figures:, thresholds:) if figures.disk_free_gib.present? && figures.disk_free_gib < @min_host_disk_gib

      # Sustained critical memory pressure is checked before the regular
      # host-memory-low threshold so callers can distinguish "we're under
      # the normal free-memory floor" from "we're below the critical
      # pressure that the RDR singles out for refusal".
      if sustained_critical_memory_pressure?(figures)
        return deny("sustained_critical_memory_pressure", figures:, thresholds:)
      end
      return deny("host_memory_low", figures:, thresholds:) if figures.memory_free_percent.present? && figures.memory_free_percent < @min_host_memory_percent
      return deny("guest_disk_unknown", figures:, thresholds:) if figures.guest_disk_free_gib.nil?

      allow(figures:, thresholds:)
    end

    # Re-check the same admission thresholds while an attempt is already
    # running. Crossing a normal threshold (disk or memory) stops further
    # admissions but does NOT terminate a running attempt — the runtime
    # watcher and timeout monitor own the host-safety termination path.
    # @spec APPLE-ATTEMPT-002
    def self.recheck_admissions(...)
      new(...).recheck_admissions
    end

    def recheck_admissions
      figures = host_capacity.snapshot
      thresholds = thresholds_payload

      return deny("host_disk_low", figures:, thresholds:) if figures.disk_free_gib.present? && figures.disk_free_gib < @min_host_disk_gib
      if sustained_critical_memory_pressure?(figures)
        return deny("sustained_critical_memory_pressure", figures:, thresholds:)
      end
      return deny("host_memory_low", figures:, thresholds:) if figures.memory_free_percent.present? && figures.memory_free_percent < @min_host_memory_percent

      allow(figures:, thresholds:)
    end

    def self.thresholds_for(
      max_active_vms: DEFAULT_MAX_ACTIVE_VMS,
      min_host_disk_gib: DEFAULT_MIN_HOST_DISK_GIB,
      min_host_memory_percent: DEFAULT_MIN_HOST_MEMORY_PERCENT,
      min_guest_disk_gib: DEFAULT_MIN_GUEST_DISK_GIB,
      critical_memory_percent: DEFAULT_CRITICAL_MEMORY_PERCENT
    )
      {
        max_active_vms:,
        min_host_disk_gib:,
        min_host_memory_percent:,
        min_guest_disk_gib:,
        critical_memory_percent:
      }
    end

    private

    attr_reader :project, :host_capacity, :max_active_vms, :min_host_disk_gib, :min_host_memory_percent,
      :min_guest_disk_gib, :critical_memory_percent, :sustained_critical_samples

    def allow(figures:, thresholds:)
      Decision.new(allowed: true, reason: "allowed", figures:, thresholds:)
    end

    def deny(reason, figures:, thresholds:)
      Decision.new(allowed: false, reason:, figures:, thresholds:)
    end

    def thresholds_payload
      {
        max_active_vms: @max_active_vms,
        min_host_disk_gib: @min_host_disk_gib,
        min_host_memory_percent: @min_host_memory_percent,
        min_guest_disk_gib: @min_guest_disk_gib,
        critical_memory_percent: @critical_memory_percent
      }
    end

    # Sustained critical pressure is "memory has been at or below
    # +critical_memory_percent+ for the last +sustained_critical_samples+
    # snapshots". A single low sample may just be a momentary spike during
    # the clone itself; only pressure sustained across the rolling history
    # blocks admission with the critical reason (APPLE-ATTEMPT-001). The
    # provider is the source of truth for the recent memory-pressure
    # window (prior samples, oldest first); the current snapshot counts
    # as the newest sample. Fewer samples than the window requirement is
    # not yet "sustained" — a lone dip still trips the regular
    # host-memory-low threshold instead.
    def sustained_critical_memory_pressure?(figures)
      return false unless figures.memory_free_percent.present?

      samples = figures.memory_pressure_window + [ figures.memory_free_percent ]
      recent = samples.last(sustained_critical_samples)
      return false if recent.size < sustained_critical_samples

      recent.all? { |sample| sample <= critical_memory_percent }
    end
  end
end
