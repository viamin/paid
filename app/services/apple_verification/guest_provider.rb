# frozen_string_literal: true

module AppleVerification
  # Provider contract for disposable macOS guests. Concrete Tart/Softnet
  # adapters must require the resolved network contract at startup.
  # @spec APPLE-NETWORK-001
  class GuestProvider
    def start_guest!(agent_run:, network_contract:)
      raise NotImplementedError, "#{self.class} must implement ##{__method__}"
    end
  end
end
