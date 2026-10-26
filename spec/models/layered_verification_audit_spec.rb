# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationAudit do
  # @spec LAYERED-VERIFY-013
  it "persists a planned audit before an issue-less run is dispatched" do
    audit = described_class.create!(
      project: create(:project),
      trigger_type: "manual_ui",
      status: "planned",
      scope_description: "Checkout payment authorization",
      sources: [ { "path" => "docs/intent/payments/payment-specs.md" } ],
      budget: { "max_checks" => 1 }
    )

    expect(audit).to be_persisted
    expect(audit.agent_run).to be_nil
  end
end
