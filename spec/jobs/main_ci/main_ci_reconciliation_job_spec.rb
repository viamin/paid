# frozen_string_literal: true

require "rails_helper"

RSpec.describe MainCiReconciliationJob do
  # @spec MAIN-CI-001 MAIN-CI-007
  it "establishes the owning tenant before reconciliation" do
    project = create(:project)
    expect(MainCi::Reconcile).to receive(:call).with(project: project) do
      expect(Current.account.id).to eq(project.account_id)
    end
    described_class.perform_now(project.id)
  end
end
