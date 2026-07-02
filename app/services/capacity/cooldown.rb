# frozen_string_literal: true

module Capacity
  # Cache-backed anti-oscillation guard for capacity-tuning decisions.
  #
  # Tuning decisions (raise/lower concurrency, raise/lower memory limits)
  # should not flip-flop. This class provides a tiny key/value cache
  # where writes store the decision and a `frozen_until` timestamp.
  # Reads ask "is this decision still frozen?" and refuse to return a
  # different decision until the cooldown elapses.
  #
  # Available to future tuning callers that need to remember the last
  # capacity decision and hold it steady for a cooldown window.
  class Cooldown
    DEFAULT_COOLDOWN = 5.minutes
    DEGRADED_COOLDOWN = 10.minutes

    class << self
      # Stores a tuning decision and freezes reads for the cooldown window.
      #
      # If a decision is still frozen (the cooldown has not elapsed) the
      # existing payload is preserved and the new value is rejected.
      # Otherwise a caller could flip the cached value from `2048` to
      # `4096` mid-window and `read` would immediately return the new
      # value, defeating the anti-oscillation contract documented on this
      # class. Use `reset!` to force a new decision before the window
      # elapses.
      def lock(key, value:, cooldown: DEFAULT_COOLDOWN, now: Time.current, cache: Rails.cache)
        previous = read(key, cache: cache, now: now)
        return previous if previous

        cache.write(cache_key(key), serialize(value, cooldown: cooldown, now: now), expires_in: cache_ttl(cooldown))
        previous
      end

      def read(key, cache: Rails.cache, now: Time.current)
        raw = cache.read(cache_key(key))
        return nil unless raw

        payload = deserialize(raw)
        return nil if payload[:frozen_until].blank?

        payload if now < payload[:frozen_until]
      rescue ArgumentError, TypeError
        nil
      end

      def frozen?(key, now: Time.current, cache: Rails.cache)
        read(key, cache: cache, now: now).present?
      end

      def reset!(key, cache: Rails.cache)
        cache.delete(cache_key(key))
      end

      private

      def cache_key(key)
        "capacity/cooldown/#{key}"
      end

      def cache_ttl(cooldown)
        cooldown.to_f * 2
      end

      def serialize(value, cooldown:, now:)
        {
          "value" => value,
          "frozen_until" => (now + cooldown).iso8601,
          "stored_at" => now.iso8601
        }
      end

      def deserialize(raw)
        raw = raw.with_indifferent_access if raw.respond_to?(:with_indifferent_access)
        {
          value: raw[:value] || raw["value"],
          frozen_until: parse_time(raw[:frozen_until] || raw["frozen_until"]),
          stored_at: parse_time(raw[:stored_at] || raw["stored_at"])
        }
      end

      def parse_time(value)
        return nil if value.blank?

        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
