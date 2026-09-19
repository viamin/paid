# frozen_string_literal: true

module AppleVerification
  # Contract for the trusted host service. Implementations must atomically
  # install the supplied network contract before starting a Tart guest.
  # @spec APPLE-NETWORK-001
  class HostService
    def start_guest!(agent_run_id:, network_contract:)
      raise NotImplementedError, "#{self.class} must implement ##{__method__}"
    end
  end
end
