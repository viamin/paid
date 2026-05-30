# frozen_string_literal: true

module Tools
  class UpdateTenantSettings < BaseTool
    authorize :update?, ->(_args) { account }, policy_class: AccountPolicy

    PERMITTED_ATTRIBUTES = %i[
      max_concurrent_runs
      max_projects
      max_users
      max_tokens_per_run
      max_monthly_cost_cents
      self_repo_full_name
      allowed_runner_keys
      auto_pick_skip_labels
      runner_preferences
      default_budgets
      guardrails
      quality_thresholds
      agent_settings
      worker_settings
      features
    ].freeze

    def self.tool_name = "update_tenant_settings"
    def self.write_operation? = true

    def self.description
      "Update tenant settings for the current account."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          settings: { type: "object" },
          confirmed: { type: "boolean" }
        },
        required: %w[settings confirmed]
      }
    end

    def self.available_to?(user:)
      policy_allows?(user:, record: user&.account, query: :update?, policy_class: AccountPolicy)
    end

    def perform(settings:, confirmed:)
      raise ArgumentError, "Confirmation required: set confirmed=true to update tenant settings" unless confirmed
      raise ArgumentError, "settings must be an object" unless settings.is_a?(Hash)

      tenant_setting = account.tenant_setting!
      tenant_setting.update!(settings.symbolize_keys.slice(*PERMITTED_ATTRIBUTES))
      tenant_setting.reload.attributes.except("id", "account_id", "created_at", "updated_at", "log_data")
    end
  end
end
