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
  # Used by Capacity::Policy to clamp memory limit oscillations and by
  # callers that want to remember "last decision" for dashboards.
  class Cooldown
    DEFAULT_COOLDOWN = 5.minutes
    DEGRADED_COOLDOWN = 10.minutes

    class << self
      def lock(key, value:, cooldown: DEFAULT_COOLDOWN, now: Time.current, cache: Rails.cache)
        previous = read(key, cache: cache)
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
