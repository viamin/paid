# frozen_string_literal: true

require "rails_helper"

RSpec.describe TenantContext, :no_db, :tenant_isolation do
  let(:account) { instance_double(Account, id: 123) }

  around do |example|
    previous_account = Current.account
    Current.account = nil
    example.run
  ensure
    Current.account = previous_account
  end

  describe ".apply!" do
    it "sets the current account and disables bypass" do
      allow(described_class).to receive(:set_config)

      described_class.apply!(account)

      expect(Current.account).to eq(account)
      expect(described_class).to have_received(:set_config).with("paid.current_account_id", 123)
      expect(described_class).to have_received(:set_config).with("paid.bypass_tenant_rls", false)
    end

    it "allows clearing the account id without raising when account is nil" do
      allow(described_class).to receive(:set_config)

      described_class.apply!(nil)

      expect(Current.account).to be_nil
      expect(described_class).to have_received(:set_config).with("paid.current_account_id", nil)
      expect(described_class).to have_received(:set_config).with("paid.bypass_tenant_rls", false)
    end
  end

  describe ".apply_system_access!" do
    it "clears the current account and enables bypass" do
      allow(described_class).to receive(:set_config)
      Current.account = account

      described_class.apply_system_access!

      expect(Current.account).to be_nil
      expect(described_class).to have_received(:set_config).with("paid.current_account_id", nil)
      expect(described_class).to have_received(:set_config).with("paid.bypass_tenant_rls", true)
    end
  end

  describe ".clear!" do
    it "clears the current account and disables bypass" do
      allow(described_class).to receive(:set_config)
      Current.account = account

      described_class.clear!

      expect(Current.account).to be_nil
      expect(described_class).to have_received(:set_config).with("paid.current_account_id", nil)
      expect(described_class).to have_received(:set_config).with("paid.bypass_tenant_rls", false)
    end
  end

  describe ".bypass_enabled?" do
    it "casts the current setting to boolean" do
      allow(described_class).to receive(:current_setting).with("paid.bypass_tenant_rls").and_return("true")

      expect(described_class.bypass_enabled?).to be(true)
      expect(described_class).to have_received(:current_setting).with("paid.bypass_tenant_rls")
    end
  end

  describe ".restore!" do
    it "restores system access when bypass was enabled" do
      allow(described_class).to receive(:apply_system_access!)
      allow(described_class).to receive(:apply!)
      allow(described_class).to receive(:clear!)

      described_class.restore!(account: account, bypass: true)

      expect(described_class).to have_received(:apply_system_access!)
      expect(described_class).not_to have_received(:apply!)
      expect(described_class).not_to have_received(:clear!)
    end

    it "casts truthy bypass values before restoring system access" do
      allow(described_class).to receive(:apply_system_access!)
      allow(described_class).to receive(:apply!)
      allow(described_class).to receive(:clear!)

      described_class.restore!(account: account, bypass: "true")

      expect(described_class).to have_received(:apply_system_access!)
      expect(described_class).not_to have_received(:apply!)
      expect(described_class).not_to have_received(:clear!)
    end

    it "restores the tenant account when bypass was disabled and an account is present" do
      allow(described_class).to receive(:apply_system_access!)
      allow(described_class).to receive(:apply!)
      allow(described_class).to receive(:clear!)

      described_class.restore!(account: account, bypass: false)

      expect(described_class).to have_received(:apply!).with(account)
      expect(described_class).not_to have_received(:apply_system_access!)
      expect(described_class).not_to have_received(:clear!)
    end

    it "casts falsey bypass values before restoring the tenant account" do
      allow(described_class).to receive(:apply_system_access!)
      allow(described_class).to receive(:apply!)
      allow(described_class).to receive(:clear!)

      described_class.restore!(account: account, bypass: "false")

      expect(described_class).to have_received(:apply!).with(account)
      expect(described_class).not_to have_received(:apply_system_access!)
      expect(described_class).not_to have_received(:clear!)
    end

    it "clears the context when bypass was disabled and no account is present" do
      allow(described_class).to receive(:apply_system_access!)
      allow(described_class).to receive(:apply!)
      allow(described_class).to receive(:clear!)

      described_class.restore!(account: nil, bypass: false)

      expect(described_class).to have_received(:clear!)
      expect(described_class).not_to have_received(:apply_system_access!)
      expect(described_class).not_to have_received(:apply!)
    end
  end

  describe ".with" do
    it "restores the previous account and database settings after yielding" do
      allow(described_class).to receive(:current_setting).with("paid.current_account_id").and_return("999")
      allow(described_class).to receive(:current_setting).with("paid.bypass_tenant_rls").and_return("true")
      allow(described_class).to receive(:set_config)
      previous_account = instance_double(Account, id: 999)
      Current.account = previous_account
      block_executed = false

      yielded_account = described_class.with(account) do
        block_executed = true
        Current.account
      end

      expect(block_executed).to be(true)
      expect(yielded_account).to eq(account)
      expect(Current.account).to eq(previous_account)
      expect(described_class).to have_received(:set_config).with("paid.current_account_id", "999")
      expect(described_class).to have_received(:set_config).with("paid.bypass_tenant_rls", "true")
    end
  end

  describe ".with_system_access" do
    it "restores the previous account and database settings after yielding" do
      allow(described_class).to receive(:current_setting).with("paid.current_account_id").and_return("123")
      allow(described_class).to receive(:current_setting).with("paid.bypass_tenant_rls").and_return("false")
      allow(described_class).to receive(:set_config)
      Current.account = account
      block_executed = false

      yielded_account = described_class.with_system_access do
        block_executed = true
        Current.account
      end

      expect(block_executed).to be(true)
      expect(yielded_account).to be_nil
      expect(Current.account).to eq(account)
      expect(described_class).to have_received(:set_config).with("paid.current_account_id", "123")
      expect(described_class).to have_received(:set_config).with("paid.bypass_tenant_rls", "false")
    end
  end
end
