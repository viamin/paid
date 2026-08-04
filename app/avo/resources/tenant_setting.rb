# frozen_string_literal: true

class Avo::Resources::TenantSetting < Avo::BaseResource
  self.title = :account_id
  self.model_class = ::TenantSetting
  self.authorization_policy = ::OperatorConsole::TenantSettingPolicy

  def fields
    field :id, as: :id
    field :account_id, as: :number
    field :max_concurrent_runs, as: :number
    field :max_projects, as: :number
    field :max_users, as: :number
    field :max_tokens_per_run, as: :number
    field :max_monthly_cost_cents, as: :number
    field :self_repo_full_name, as: :text
    field :queue_fairness_mode, as: :select, options: ::TenantSetting::QUEUE_FAIRNESS_MODES.index_with(&:humanize)
    field :allowed_runner_keys, as: :tags
    field :runner_preferences, as: :code, language: "javascript", pretty_generated: true
    field :default_budgets, as: :code, language: "javascript", pretty_generated: true
    field :guardrails, as: :code, language: "javascript", pretty_generated: true
    field :quality_thresholds, as: :code, language: "javascript", pretty_generated: true
    field :agent_settings, as: :code, language: "javascript", pretty_generated: true
    field :worker_settings, as: :code, language: "javascript", pretty_generated: true
    field :features, as: :code, language: "javascript", pretty_generated: true
    field :created_at, as: :date_time, readonly: true
    field :updated_at, as: :date_time, readonly: true
  end
end
