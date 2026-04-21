# frozen_string_literal: true

require "rails_helper"

RSpec.describe Account do
  describe "associations" do
    it { is_expected.to have_many(:users).dependent(:destroy) }
    it { is_expected.to have_many(:account_memberships).dependent(:destroy) }
    it { is_expected.to have_many(:members).through(:account_memberships).source(:user) }
    it { is_expected.to have_many(:projects).dependent(:destroy) }
    it { is_expected.to have_many(:github_tokens).dependent(:destroy) }
    it { is_expected.to have_one(:tenant_setting).dependent(:destroy) }
    it { is_expected.to have_many(:billing_invoices).dependent(:destroy) }
    it { is_expected.to have_many(:billing_periods).dependent(:destroy) }
    it { is_expected.to have_many(:billing_plans).dependent(:destroy) }
  end

  describe "validations" do
    subject { build(:account) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_uniqueness_of(:slug) }

    it "requires slug when name is blank" do
      account = described_class.new(name: nil, slug: nil)
      expect(account).not_to be_valid
      expect(account.errors[:slug]).to include("can't be blank")
    end

    it "validates slug format" do
      account = build(:account, slug: "Invalid Slug!")
      expect(account).not_to be_valid
      expect(account.errors[:slug]).to include("can only contain lowercase letters, numbers, and hyphens")
    end

    it { is_expected.to validate_numericality_of(:default_max_tokens_per_run).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(2_147_483_647) }

    it "allows valid slug formats" do
      account = build(:account, slug: "valid-slug-123")
      expect(account).to be_valid
    end
  end

  describe "slug generation" do
    it "generates a slug from the name if not provided" do
      account = described_class.new(name: "My Company")
      account.valid?
      expect(account.slug).to eq("my-company")
    end

    it "does not override an existing slug" do
      account = described_class.new(name: "My Company", slug: "custom-slug")
      account.valid?
      expect(account.slug).to eq("custom-slug")
    end

    it "handles duplicate slugs by appending a counter" do
      create(:account, slug: "my-company")
      account = described_class.new(name: "My Company")
      account.valid?
      expect(account.slug).to eq("my-company-1")
    end

    it "increments the counter for multiple duplicates" do
      create(:account, slug: "my-company")
      create(:account, slug: "my-company-1")
      account = described_class.new(name: "My Company")
      account.valid?
      expect(account.slug).to eq("my-company-2")
    end
  end

  describe "status" do
    it "defaults to active" do
      expect(create(:account)).to be_active
    end

    it "defines the expected enum values" do
      expect(described_class.statuses).to eq("active" => 0, "suspended" => 1, "deactivated" => 2)
    end
  end

  describe "#suspend!" do
    it "transitions active account to suspended" do
      account = create(:account)
      freeze_time do
        account.suspend!
        expect(account).to be_suspended
        expect(account.suspended_at).to eq(Time.current)
      end
    end

    it "raises for already suspended account" do
      account = create(:account, status: :suspended, suspended_at: Time.current)
      expect { account.suspend! }.to raise_error(Account::InvalidTransitionError)
    end

    it "raises for deactivated account" do
      account = create(:account, status: :deactivated, deactivated_at: Time.current)
      expect { account.suspend! }.to raise_error(Account::InvalidTransitionError)
    end
  end

  describe "#reactivate!" do
    it "transitions suspended account to active" do
      account = create(:account, status: :suspended, suspended_at: Time.current)
      account.reactivate!
      expect(account).to be_active
      expect(account.suspended_at).to be_nil
    end

    it "transitions deactivated account to active" do
      account = create(:account, status: :deactivated, deactivated_at: Time.current)
      account.reactivate!
      expect(account).to be_active
      expect(account.deactivated_at).to be_nil
    end

    it "raises for already active account" do
      account = create(:account)
      expect { account.reactivate! }.to raise_error(Account::InvalidTransitionError)
    end
  end

  describe "#deactivate!" do
    it "transitions suspended account to deactivated" do
      account = create(:account, status: :suspended, suspended_at: Time.current)
      freeze_time do
        account.deactivate!
        expect(account).to be_deactivated
        expect(account.deactivated_at).to eq(Time.current)
      end
    end

    it "raises for active account" do
      account = create(:account)
      expect { account.deactivate! }.to raise_error(Account::InvalidTransitionError)
    end
  end

  describe "#tenant_setting!" do
    it "returns existing tenant_setting" do
      account = create(:account)
      setting = create(:tenant_setting, account: account)
      expect(account.tenant_setting!).to eq(setting)
    end

    it "creates tenant_setting if none exists" do
      account = create(:account)
      expect { account.tenant_setting! }.to change(TenantSetting, :count).by(1)
      expect(account.tenant_setting!.account).to eq(account)
    end
  end

  describe "#scheduler_paused?" do
    it "is false by default" do
      expect(create(:account).scheduler_paused?).to be false
    end

    it "is true when scheduler_paused_at is set" do
      expect(create(:account, scheduler_paused_at: Time.current).scheduler_paused?).to be true
    end
  end

  describe "dependent billing records" do
    it "destroys invoices, periods, and plans with the account" do
      account = create(:account)
      plan = create(:billing_plan, account: account)
      period = create(:billing_period, account: account, billing_plan: plan)
      create(:billing_invoice, account: account, billing_period: period)

      expect { account.destroy! }
        .to change(BillingInvoice, :count).by(-1)
        .and change(BillingPeriod, :count).by(-1)
        .and change(BillingPlan, :count).by(-1)
    end
  end
end
