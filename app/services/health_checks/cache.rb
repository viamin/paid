# frozen_string_literal: true

module HealthChecks
  # Rails.cache wrapper for health check results.
  # Page reads cache; the daily sweep refreshes it.
  class Cache
    KEY_PREFIX = "project_health"
    DEFAULT_TTL = 1.day

    class << self
      # Reads the cached Result for +subject+ (a Project, Runner, etc.).
      def read(subject)
        Rails.cache.read(cache_key(subject))
      end

      # Writes a Result into the cache for +subject+.
      def write(subject, result, ttl: DEFAULT_TTL)
        Rails.cache.write(cache_key(subject), result, expires_in: ttl)
      end

      # Clears the cached entry for +subject+.
      def clear(subject)
        Rails.cache.delete(cache_key(subject))
      end
      alias_method :delete, :clear

      private

      def cache_key(subject)
        "#{KEY_PREFIX}/#{subject.class.model_name.param_key}/#{subject.id}"
      end
    end
  end
end
