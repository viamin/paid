# frozen_string_literal: true

module OperatorTools
  class GetTenantSetting < ResourceGetTool
    authorize :show?, ->(args) { TenantSetting.find(args.fetch(:id)) }, policy_class: OperatorConsole::TenantSettingPolicy

    def self.tool_name = "operator_get_tenant_setting"
    def self.model_class = TenantSetting
    def self.policy_class = OperatorConsole::TenantSettingPolicy
    def self.resource_label = "tenant setting"
    def self.attributes = %i[
      id account_id max_concurrent_runs max_projects max_users max_tokens_per_run max_monthly_cost_cents
      self_repo_full_name allowed_runner_keys runner_preferences default_budgets guardrails
      quality_thresholds agent_settings worker_settings features created_at updated_at
    ]
  end
end
