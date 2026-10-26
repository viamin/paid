# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Request do
  # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-021
  it "creates an issue-less audit run with its resolved scope, provenance, revision, budget, and plan" do
    project = create(:project)
    user = create(:user, :member, account: project.account)
    obligation = create(:layered_verification_obligation, project:, external_revision: "abc123")

    run = described_class.call(
      project:,
      user:,
      obligations: [ obligation ],
      sources: [ "docs/intent/payments" ],
      target_revision: "abc123",
      budget: { "max_tokens" => 1000 },
      runner_resolver: ->(*) { [ nil, "codex" ] }
    )

    expect(run).to have_attributes(goal: "layered_verification_audit", issue_id: nil, initiating_user: user)
    expect(run.external_metadata).to include(
      "target_revision" => "abc123",
      "budget" => { "max_tokens" => 1000 },
      "obligation_ids" => [ obligation.id ]
    )
    expect(run.external_metadata.fetch("verification_plan")).to include("selected_checks")
  end
end
