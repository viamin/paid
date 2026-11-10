# frozen_string_literal: true

module Integrations
  class RevokeLinearToken
    def self.call(...) = new(...).call

    def initialize(token:)
      @token = token
    end

    # @spec UNIFIED-WORK-ITEMS-002
    def call
      TrackerConfiguration.transaction do
        token.revoke!
        connection = token.account.tracker_configuration
        if connection&.linear_token_id == token.id
          connection.update!(linear_token: nil, enabled: false, connection_health: "disconnected",
            last_sync_error: nil)
        end
      end
    end

    private

    attr_reader :token
  end
end
