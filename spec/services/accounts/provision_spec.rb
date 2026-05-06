# frozen_string_literal: true

require "rails_helper"

RSpec.describe Accounts::Provision do
  describe ".call" do
    it "creates an account with the given name" do
      result = described_class.call(name: "Acme Corp")

      expect(result).to be_success
      expect(result.account).to be_persisted
      expect(result.account.name).to eq("Acme Corp")
    end

    it "defaults to trial plan" do
      result = described_class.call(name: "Trial Org")

      expect(result.account.plan).to eq("trial")
    end

    it "creates tenant settings with plan-based defaults" do
      result = described_class.call(name: "Pro Org", plan: "professional")

      setting = result.account.tenant_setting
      expect(setting).to be_present
      expect(setting.max_concurrent_runs).to eq(10)
      expect(setting.max_projects).to eq(50)
      expect(setting.max_users).to eq(25)
      expect(setting.max_tokens_per_run).to eq(10_000_000)
    end

    it "creates a billing plan matching the account plan" do
      result = described_class.call(name: "Pro Org", plan: "professional")

      billing_plan = result.account.billing_plans.first
      expect(billing_plan).to be_present
      expect(billing_plan.name).to eq("Professional")
      expect(billing_plan.billing_model).to eq("per_run")
      expect(billing_plan.base_rate_cents).to eq(4900)
    end

    it "starts the onboarding flow" do
      result = described_class.call(name: "New Org")

      expect(result.account.onboarding_steps).to be_present
      expect(result.account.onboarding_steps.count).to eq(OnboardingStep::STEPS.size)
    end

    it "generates a slug from the name" do
      result = described_class.call(name: "My Great Company")

      expect(result.account.slug).to eq("my-great-company")
    end

    it "returns errors when name is blank" do
      result = described_class.call(name: "")

      expect(result).not_to be_success
      expect(result.errors).to include(a_string_matching(/Name/i))
    end

    it "rolls back all records on failure" do
      allow(Onboarding::StartOnboarding).to receive(:call).and_raise(
        ActiveRecord::RecordInvalid.new(Account.new)
      )

      expect {
        described_class.call(name: "Rollback Test")
      }.not_to change(Account, :count)
    end

    context "with enterprise plan" do
      it "sets high resource limits" do
        result = described_class.call(name: "Big Corp", plan: "enterprise")

        setting = result.account.tenant_setting
        expect(setting.max_concurrent_runs).to eq(100)
        expect(setting.max_projects).to eq(1000)
        expect(setting.max_users).to eq(500)
      end
    end

    context "with trial plan" do
      it "sets trial_ends_at" do
        result = described_class.call(name: "Trial Corp", plan: "trial")

        expect(result.account.trial_ends_at).to be_within(1.minute).of(14.days.from_now)
      end
    end

    context "when called from inside an existing tenant context", :tenant_isolation do
      it "succeeds even when RLS is scoped to another account" do
        existing_account = TenantContext.with_system_access { create(:account) }

        result = TenantContext.with(existing_account) do
          described_class.call(name: "New Tenant From Existing")
        end

        expect(result).to be_success
        expect(result.account.name).to eq("New Tenant From Existing")

        TenantContext.with_system_access do
          expect(result.account.tenant_setting).to be_present
          expect(result.account.billing_plans.count).to eq(1)
          expect(result.account.onboarding_steps.count).to eq(OnboardingStep::STEPS.size)
        end
      end
    end
  end
end
