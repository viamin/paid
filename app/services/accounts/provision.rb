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

      TenantContext.with_system_access do
        ActiveRecord::Base.transaction do
          account = create_account
          create_tenant_setting(account)
          create_billing_plan(account)
          start_onboarding(account)
        end
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
      account.create_tenant_setting!(TenantSetting.defaults_for_plan(plan))
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
