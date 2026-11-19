# frozen_string_literal: true

require "rails_helper"

RSpec.describe CapybaraTenantContext, :tenant_isolation do
  # @spec POSTGRESQL-PERSISTENCE-012
  it "restores the fixture baseline after a scoped controller clears its session" do
    account = TenantContext.with_system_access { create(:account) }
    TenantContext.clear!
    app = lambda do |_environment|
      TenantContext.apply!(account)
      expect(ActiveRecord::Base.connection.select_value("SELECT paid_current_account_id()")).to eq(account.id)
      expect(TenantContext.bypass_enabled?).to be(false)
      TenantContext.clear!
      [ 200, {}, [] ]
    end

    expect(described_class.new(app).call({})).to eq([ 200, {}, [] ])
    expect(TenantContext.bypass_enabled?).to be(true)
  end

  # @spec POSTGRESQL-PERSISTENCE-012
  it "restores the fixture baseline when a controller raises" do
    TenantContext.clear!
    app = ->(_environment) { TenantContext.clear!; raise "request failed" }

    expect { described_class.new(app).call({}) }.to raise_error("request failed")
    expect(TenantContext.bypass_enabled?).to be(true)
  end
end
