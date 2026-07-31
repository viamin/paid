# frozen_string_literal: true

module Runners
  # Timezone-aware evaluator for a runner's +time_restrictions+ config.
  #
  # Encapsulates all window-matching logic so selection paths
  # (RunnerResolver, RunAgentActivity#build_runner_order) can ask simple
  # boolean questions without duplicating timezone math. The clock is
  # injectable (+now:+) for deterministic testing.
  #
  # @spec RUNNER-SCHED-003, RUNNER-SCHED-004, RUNNER-SCHED-005,
  #   RUNNER-SCHED-007, RUNNER-SCHED-010
  class TimeWindowCheck
    # @spec RUNNER-SCHED-002
    MODES = %w[block deprioritize].freeze

    attr_reader :config, :now

    # @param config [Hash, nil] the runner's +time_restrictions+ JSONB value
    # @param now [Time] the reference instant (defaults to Time.current)
    def initialize(config, now: Time.current)
      @config = normalize_config(config)
      @now = now
    end

    def restrictions_enabled?
      config[:mode].present? && windows.any?
    end

    def mode
      config[:mode]
    end

    def block_mode?
      restrictions_enabled? && mode == "block"
    end

    def deprioritize_mode?
      restrictions_enabled? && mode == "deprioritize"
    end

    # True when the reference instant falls inside any configured window.
    # @spec RUNNER-SCHED-005
    def restricted_at?(time = now)
      return false unless restrictions_enabled?
      return false if time.nil?

      hour = current_hour(time)
      windows.any? { |w| hour_in_window?(hour, w) }
    end

    # True when block-mode AND currently inside a window.
    # @spec RUNNER-SCHED-005
    def blocked_at?(time = now)
      block_mode? && restricted_at?(time)
    end

    # True when deprioritize-mode AND currently inside a window.
    # @spec RUNNER-SCHED-007
    def deprioritized_at?(time = now)
      deprioritize_mode? && restricted_at?(time)
    end

    # Computes the next instant the runner becomes available — the start of
    # the first non-restricted hour boundary after the reference time in the
    # configured timezone. Returns nil when restrictions are not active at
    # the reference time (already available).
    #
    # @spec RUNNER-SCHED-010
    def next_available_at(time = now)
      return nil unless restrictions_enabled?
      return nil unless restricted_at?(time)

      tz = resolved_timezone
      next_hour_boundary = (time.in_time_zone(tz) + 1.hour).beginning_of_hour

      24.times do |i|
        candidate = next_hour_boundary + i.hours
        return candidate.utc unless windows.any? { |w| hour_in_window?(candidate.hour, w) }
      end

      # Degenerate: all 24 hours restricted. Return nil so TimeWindowPark
      # falls through to the normal no-runnable-runner path instead of
      # parking the run into a tight requeue loop. Validation should reject
      # this, but this is the defense-in-depth guard.
      nil
    end

    private

    def windows
      config[:windows]
    end

    def current_hour(time)
      time.in_time_zone(resolved_timezone).hour
    end

    def resolved_timezone
      ActiveSupport::TimeZone[config[:timezone]] || ActiveSupport::TimeZone["UTC"]
    end

    # An hour H is inside window { start_hour: S, end_hour: E } when:
    # - Normal window (S < E): S <= H < E (end exclusive)
    # - Wraparound window (S > E): H >= S || H < E
    # A zero-width window (S == E) matches nothing.
    # @spec RUNNER-SCHED-003, RUNNER-SCHED-004
    def hour_in_window?(hour, window)
      start_h = window[:start_hour]
      end_h = window[:end_hour]
      return false if start_h == end_h

      if start_h < end_h
        hour >= start_h && hour < end_h
      else
        hour >= start_h || hour < end_h
      end
    end

    def normalize_config(raw)
      return {} if raw.blank?
      return {} unless raw.is_a?(Hash)

      raw = raw.deep_symbolize_keys
      mode = raw[:mode].to_s.presence
      timezone = raw[:timezone].to_s.presence || "UTC"
      windows = Array(raw[:windows]).map { |w| normalize_window(w) }.compact

      { mode: mode, timezone: timezone, windows: windows }
    end

    def normalize_window(raw)
      return unless raw.is_a?(Hash)

      raw = raw.deep_symbolize_keys
      start_h = Integer(raw[:start_hour], exception: false)
      end_h = Integer(raw[:end_hour], exception: false)
      return unless start_h && end_h
      return unless start_h.between?(0, 23) && end_h.between?(0, 23)

      { start_hour: start_h, end_hour: end_h }
    end
  end
end
