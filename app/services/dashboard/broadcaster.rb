# frozen_string_literal: true

module Dashboard
  class Broadcaster
    def self.call(...)
      new(...).call
    end

    def initialize(account:)
      @account = account
    end

    # Called by DashboardBroadcastJob when an agent run finishes.
    # Invalidates aggregate caches so the next lazy-frame load picks up fresh
    # data, and pushes an immediate live-stats update over Turbo Streams.
    # Metrics and performance frames are intentionally NOT pushed in real time
    # because they run expensive aggregate queries; they refresh on the next
    # user-initiated navigation or page reload.
    def call
      invalidate_caches
      broadcast_live_stats
    end

    private

    attr_reader :account

    def invalidate_caches
      Rails.cache.delete("dashboard/live_stats/#{account.id}")
      Dashboard::CacheVersion.bump(account)
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
