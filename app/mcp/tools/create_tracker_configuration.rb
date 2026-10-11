# frozen_string_literal: true

module Tools
  # @spec ONBOARD-CHAT-006 ONBOARD-CHAT-007 ONBOARD-CHAT-012
  class CreateTrackerConfiguration < BaseTool
    authorize :create?, ->(args) { configurable_for(args.fetch(:configurable_type), args[:configurable_id]) }, policy_class: TrackerConfigurationPolicy

    def self.tool_name = "create_tracker_configuration"
    def self.write_operation? = true
    def self.description = "Create a tracker configuration, or return a connect link for OAuth trackers."

    def self.input_schema
      { type: "object", properties: {
        tracker_type: { type: "string", enum: TrackerConfiguration::TRACKER_TYPES }, configurable_type: { type: "string", enum: TrackerConfiguration::CONFIGURABLE_TYPES }, configurable_id: { type: "integer" },
        integration_credential_id: { type: "integer" }, base_url: { type: "string" }, confirmed: { type: "boolean" }
      }, required: %w[tracker_type configurable_type confirmed] }
    end

    def perform(tracker_type:, configurable_type:, confirmed:, configurable_id: nil, integration_credential_id: nil, base_url: nil)
      raise ArgumentError, "Confirmation required: set confirmed=true to create a tracker configuration" unless confirmed
      return { status: "connect_required", connect_url: "/integrations/#{tracker_type}/connect" } if oauth_tracker?(tracker_type, integration_credential_id)

      tracker = configurable(configurable_type, configurable_id).build_tracker_configuration(
        tracker_type:, base_url: base_url.presence || Project::DEFAULT_ISSUE_TRACKER_URLS[tracker_type], integration_credential: credential(integration_credential_id), created_by: user
      )
      tracker.save!
      tracker.attributes.slice("id", "tracker_type", "base_url", "enabled", "configurable_type", "configurable_id")
    end

    private

    def configurable_for(type, id)
      case type
      when "Account" then current_user.account
      when "User" then current_user
      when "Project" then policy_scope(Project).find(id)
      else raise ArgumentError, "Invalid configurable type"
      end
    end

    def configurable(type, id)
      configurable_for(type, id)
    end

    def credential(id)
      return if id.blank?

      account.integration_credentials.active.find(id)
    end

    def oauth_tracker?(type, credential_id)
      credential_id.blank? && Integrations::CredentialCatalog.lookup(type)&.fetch(:auth_kinds, [])&.include?("oauth_token")
    end
  end
end
