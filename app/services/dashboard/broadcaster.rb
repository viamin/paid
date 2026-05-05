# frozen_string_literal: true

module Dashboard
  class Broadcaster
    def self.call(...)
      new(...).call
    end

    def initialize(account:)
      @account = account
    end

    def call
      invalidate_caches
      broadcast_live_stats
    end

    private

    attr_reader :account

    def invalidate_caches
      Rails.cache.delete("dashboard/live_stats/#{account.id}")
    end

    def broadcast_live_stats
      Turbo::StreamsChannel.broadcast_update_to(
        [ account, :live_dashboard ],
        target: "live-stats",
        partial: "dashboard/live_stats",
        locals: { stats: Dashboard::LiveStats.call(account: account) }
      )
    end
  end
end
