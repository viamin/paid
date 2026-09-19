# frozen_string_literal: true

module AppleVerification
  # The concrete provider for Paid's narrow Tart host-service API. The host
  # service installs the supplied contract as part of its start operation, so
  # it cannot start a guest before receiving Paid's policy decision.
  # @spec APPLE-NETWORK-001
  class TartProvider < GuestProvider
    def initialize(host_service:)
      @host_service = host_service
    end

    def start_guest!(agent_run:, network_contract:)
      raise MissingNetworkContractError, "Apple guest startup requires a Paid network contract" if network_contract.blank?

      host_service.start_guest!(agent_run_id: agent_run.id, network_contract: network_contract)
    end

    private

    attr_reader :host_service
  end
end
