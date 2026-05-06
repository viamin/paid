# frozen_string_literal: true

module Accounts
  # Provisions a new tenant account with all required infrastructure:
  # - Account record with generated slug
  # - TenantSetting with plan-based defaults
  # - Default BillingPlan
  # - Onboarding wizard steps
  #
  # @example
  #   result = Accounts::Provision.call(name: "Acme Corp", plan: "professional")
  #   result.account  # => Account instance
  #   result.success? # => true
  class Provision
    Result = Struct.new(:account, :errors, keyword_init: true) do
      def success?
        errors.blank?
      end
    end

    PLAN_DEFAULTS = {
      "trial" => {
        max_concurrent_runs: 2,
        max_projects: 3,
        max_users: 5,
        max_tokens_per_run: 5_000_000
      },
      "free" => {
        max_concurrent_runs: 3,
        max_projects: 5,
        max_users: 10,
        max_tokens_per_run: 5_000_000
      },
      "professional" => {
        max_concurrent_runs: 10,
        max_projects: 50,
        max_users: 25,
        max_tokens_per_run: 10_000_000
      },
      "enterprise" => {
        max_concurrent_runs: 100,
        max_projects: 1000,
        max_users: 500,
        max_tokens_per_run: 2_147_483_647
      }
    }.freeze

    BILLING_PLAN_TEMPLATES = {
      "trial" => { name: "Trial", billing_model: "flat_rate", base_rate_cents: 0, period_type: "monthly" },
      "free" => { name: "Free", billing_model: "flat_rate", base_rate_cents: 0, period_type: "monthly" },
      "professional" => { name: "Professional", billing_model: "per_run", base_rate_cents: 4900, period_type: "monthly",
                          included_runs: 100, per_run_rate_cents: 50 },
      "enterprise" => { name: "Enterprise", billing_model: "flat_rate", base_rate_cents: 49900, period_type: "monthly" }
    }.freeze

    attr_reader :name, :plan

    def initialize(name:, plan: "trial")
      @name = name
      @plan = plan
    end

    def self.call(...)
      new(...).call
    end

    def call
      account = nil

      ActiveRecord::Base.transaction do
        account = create_account
        create_tenant_setting(account)
        create_billing_plan(account)
        start_onboarding(account)
      end

      Result.new(account: account)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(account: nil, errors: e.record&.errors&.full_messages || [ e.message ])
    end

    private

    def create_account
      Account.create!(name: name, plan: plan)
    end

    def create_tenant_setting(account)
      defaults = PLAN_DEFAULTS.fetch(plan, PLAN_DEFAULTS["trial"])
      account.create_tenant_setting!(defaults)
    end

    def create_billing_plan(account)
      template = BILLING_PLAN_TEMPLATES.fetch(plan, BILLING_PLAN_TEMPLATES["trial"])
      account.billing_plans.create!(template)
    end

    def start_onboarding(account)
      Onboarding::StartOnboarding.call(account: account)
    end
  end
end
