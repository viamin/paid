# frozen_string_literal: true

module Dashboard
  class CacheVersion
    VERSION_TTL = 30.days

    def self.current(account)
      new(account:).current
    end

    def self.bump(account)
      new(account:).bump
    end

    def initialize(account:)
      @account = account
    end

    def current
      Rails.cache.fetch(cache_key, expires_in: VERSION_TTL) { initial_version }
    end

    def bump
      current
      Rails.cache.increment(cache_key, 1, expires_in: VERSION_TTL) || write_next_version
    end

    private

    attr_reader :account

    def cache_key
      "dashboard/version/#{account.id}"
    end

    def initial_version
      Time.current.to_i
    end

    def write_next_version
      next_version = current + 1
      Rails.cache.write(cache_key, next_version, expires_in: VERSION_TTL)
      next_version
    end
  end
end
