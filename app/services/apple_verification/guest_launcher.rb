# frozen_string_literal: true

module AppleVerification
  # Admits an Apple guest only after its persisted egress policy has become a
  # provider contract. Providers receive the contract as a required startup
  # argument, so they cannot boot a guest with an implicit network policy.
  # @spec APPLE-NETWORK-001
  class GuestLauncher
    def initialize(provider:, proxy_url:, dns_server:)
      @provider = provider
      @proxy_url = proxy_url
      @dns_server = dns_server
    end

    def call(agent_run:)
      provider.start_guest!(agent_run: agent_run, network_contract: network_policy(agent_run).contract)
    end

    private

    attr_reader :provider, :proxy_url, :dns_server

    def network_policy(agent_run)
      GuestNetworkPolicy.resolve_and_persist!(agent_run: agent_run, proxy_url: proxy_url, dns_server: dns_server)
    end
  end
end
