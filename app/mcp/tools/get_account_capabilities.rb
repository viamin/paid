# frozen_string_literal: true

module Tools
  # @spec ONBOARD-CHAT-005 ONBOARD-CHAT-012
  class GetAccountCapabilities < BaseTool
    authorize :show?, ->(_args) { current_user.account }, policy_class: ApplicationPolicy

    def self.tool_name = "get_account_capabilities"
    def self.description = "List connected GitHub, tracker, and Docker capabilities without secrets."

    def perform
      {
        github_installations: account.github_installations.active.map { |item| { id: item.id, name: item.display_name, repositories: item.cached_repositories } },
        github_tokens: account.github_tokens.active.map { |item| item.attributes.slice("id", "name", "validation_status", "expires_at") },
        tracker_configurations: policy_scope(TrackerConfiguration).map { |item| item.attributes.slice("id", "tracker_type", "base_url", "enabled", "configurable_type", "configurable_id") },
        docker_hosts: account.docker_hosts.map { |item| item.attributes.slice("id", "display_name", "identifier", "readiness_status", "last_checked_at", "enabled") }
      }
    end
  end
end
