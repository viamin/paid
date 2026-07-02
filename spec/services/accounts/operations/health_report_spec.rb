# frozen_string_literal: true

require "rails_helper"

RSpec.describe Accounts::Operations::HealthReport do
  describe ".call" do
    let(:account) { create(:account, name: "Acme") }
    let(:tenant_setting) { account.tenant_setting! }

    before do
      allow(Scaling::QueueMonitor).to receive(:cached_for_account).and_return(
        Scaling::QueueMonitor::Result.new(queue_depths: [], alerts: [], healthy?: true)
      )
      allow(::Dashboard::RunnerHealth).to receive(:call).and_return(total: 0, available: 0, runners: [])
    end

    it "includes auto-capacity data in the exported operations dashboard" do
      auto_capacity = { status: :healthy, effective_recommended_concurrency: 3 }
      allow(Accounts::Operations::Dashboard).to receive(:call).and_return(
        {
          capacity: { auto_capacity: auto_capacity }
        }
      )

      report = described_class.call(account:, tenant_setting:, billing_visible: true)

      expect(Accounts::Operations::Dashboard).to have_received(:call).with(
        account:,
        tenant_setting:,
        billing_visible: true,
        include_auto_capacity: true
      )
      expect(report.dig(:operations_dashboard, :capacity, :auto_capacity)).to eq(auto_capacity)
    end
  end
end
