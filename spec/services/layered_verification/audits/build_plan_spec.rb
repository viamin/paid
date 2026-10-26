# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::BuildPlan do
  # @spec LAYERED-VERIFY-021
  it "records an explicit uncertainty plan when no check selection is available" do
    project = create(:project)
    scope = LayeredVerification::Audits::ResolveScope::Scope.new(
      scope_description: "Checkout payment authorization",
      sources: [ { "path" => "docs/intent/payments/payment-specs.md" } ],
      target_revision: "abc123",
      budget: { "max_checks" => 1, "max_duration_seconds" => 60 },
      obligations: [],
      notes: []
    )

    plan = described_class.call(project:, obligations: [], scope:, selector: -> { nil })

    expect(plan.selected_checks).to eq([])
    expect(plan.document["obligation_external_identities"]).to eq([])
    expect(plan.residual_gaps).to include("No check established coverage for the obligations in scope.")
  end
end
