# frozen_string_literal: true

module AppleVerification
  # The Apple verification control-plane entry point. Keep the host-service
  # dependency here so all Tart guest starts pass through GuestLauncher.
  # @spec APPLE-NETWORK-001
  class StartGuest
    def initialize(agent_run:, host_service:, proxy_url:, dns_server:)
      @agent_run = agent_run
      @host_service = host_service
      @proxy_url = proxy_url
      @dns_server = dns_server
    end

    def call
      launcher.call(agent_run: agent_run)
    end

    private

    attr_reader :agent_run, :host_service, :proxy_url, :dns_server

    def launcher
      GuestLauncher.new(provider: TartProvider.new(host_service: host_service), proxy_url: proxy_url, dns_server: dns_server)
    end
  end
end
