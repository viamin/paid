# frozen_string_literal: true

module Github
  # Collects and reports cache performance statistics for GitHub API data.
  #
  # Tracks hit rates, miss rates, and invalidation counts per resource type.
  # Uses ActiveSupport::Notifications events emitted by CacheService.
  #
  # @example
  #   stats = Github::CacheStats.snapshot
  #   stats[:hit_rate]  # => 0.85
  class CacheStats
    COUNTER_TTL = 1.hour
    COUNTER_NAMESPACE = "github_cache_stats"

    STAT_KEYS = %i[hits misses invalidations].freeze

    class << self
      def snapshot
        hits = read_counter(:hits)
        misses = read_counter(:misses)
        invalidations = read_counter(:invalidations)
        total = hits + misses

        {
          hits: hits,
          misses: misses,
          invalidations: invalidations,
          total_requests: total,
          hit_rate: total.positive? ? (hits.to_f / total).round(3) : 0.0,
          miss_rate: total.positive? ? (misses.to_f / total).round(3) : 0.0
        }
      end

      def record_hit
        increment_counter(:hits)
      end

      def record_miss
        increment_counter(:misses)
      end

      def record_invalidation
        increment_counter(:invalidations)
      end

      def reset!
        STAT_KEYS.each { |key| Rails.cache.delete(counter_key(key)) }
      end

      def subscribe!
        [
          ActiveSupport::Notifications.subscribe("github_cache.hit") { record_hit },
          ActiveSupport::Notifications.subscribe("github_cache.miss") { record_miss },
          ActiveSupport::Notifications.subscribe("github_cache.invalidate") { record_invalidation }
        ]
      end

      private

      def counter_key(stat)
        hour = Time.current.beginning_of_hour.to_i
        "#{COUNTER_NAMESPACE}:#{stat}:#{hour}"
      end

      def increment_counter(stat)
        key = counter_key(stat)
        current = Rails.cache.read(key).to_i
        Rails.cache.write(key, current + 1, expires_in: COUNTER_TTL)
      end

      def read_counter(stat)
        Rails.cache.read(counter_key(stat)).to_i
      end
    end
  end
end
