# frozen_string_literal: true

module Integrations
  # Selects one existing LinearToken as the account's active workspace key.
  class ConnectLinearToken
    class ConfigurationConflict < StandardError; end

    def self.call(...) = new(...).call

    def initialize(token:)
      @token = token
    end

    # @spec UNIFIED-WORK-ITEMS-002
    def call
      TrackerConfiguration.transaction do
        connection = token.account.tracker_configuration
        if connection && connection.tracker_type != "linear"
          raise ConfigurationConflict, "An account tracker configuration already exists; change it before connecting Linear."
        end

        token.save!
        connection ||= token.account.build_tracker_configuration(tracker_type: "linear", created_by: token.created_by)
        connection.assign_attributes(linear_token: token, integration_credential: nil,
          enabled: true, connection_health: "unknown", last_synced_at: nil, last_sync_error: nil)
        connection.save!
      end
      token
    end

    private

    attr_reader :token
  end
end
