# frozen_string_literal: true

module ClaudeLoginSessions
  class Coordination
    LIVE_TTL = 10.seconds
    POP_TIMEOUT = 1

    # Default Redis URL used when `REDIS_URL` is unset. Matches the dev
    # fallback in `config/initializers/rails_performance.rb` so an unset
    # environment variable never crashes with `KeyError` mid-flow. Production
    # deploys are expected to override this with a real Redis URL — the
    # production validator emits a `production_config.unsafe_default` warning
    # when the resulting address is still a localhost.
    DEFAULT_REDIS_URL = "redis://127.0.0.1:6379/0"

    def self.redis
      @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", DEFAULT_REDIS_URL))
    end

    def initialize(session:, redis: self.class.redis)
      @session = session
      @redis = redis
    end

    def register_live!
      redis.set(live_key, "1", ex: LIVE_TTL.to_i)
    end

    def refresh_live!
      redis.expire(live_key, LIVE_TTL.to_i)
    end

    def live?
      redis.exists?(live_key)
    end

    def enqueue_code(code)
      redis.rpush(queue_key, code)
    end

    def pop_code(timeout: POP_TIMEOUT)
      redis.blpop(queue_key, timeout: timeout)&.last
    end

    def clear!
      redis.del(live_key, queue_key)
    end

    private

    attr_reader :session, :redis

    def live_key
      "claude_login_sessions:#{session.external_id}:live"
    end

    def queue_key
      "claude_login_sessions:#{session.external_id}:codes"
    end
  end
end
