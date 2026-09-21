# frozen_string_literal: true

module AgentRuns
  module AppleVerification
    # A single destination attempt a guest asks the contract to authorize.
    # +dns_server+ and +proxy_override+ are only set when the guest reports
    # (or is observed) using something other than the contract's Paid DNS
    # resolver / proxy endpoint — the default +nil+ means "used the Paid
    # path," which is the only compliant shape.
    # @spec APPLE-NETWORK-002
    GuestNetworkRequest = Struct.new(:host, :port, :scheme, :dns_server, :proxy_override, keyword_init: true)
  end
end
