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
      stats = Dashboard::Stats.call(account: account)

      Turbo::StreamsChannel.broadcast_replace_to(
        account, :dashboard_updates,
        target: "dashboard",
        partial: "dashboard/content",
        locals: { stats: stats, account: account }
      )
    end

    private

    attr_reader :account
  end
end
