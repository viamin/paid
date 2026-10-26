# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016
  it "exposes decision evidence without resolving a deferred finding" do
    run = create(:agent_run, issue: nil, goal: "layered_verification_audit", custom_prompt: "audit")
    obligation = create(:layered_verification_obligation, project: run.project)
    finding = LayeredVerificationFinding.create!(
      project: run.project, obligation:, audit_run: run, cause_signature: "contradiction",
      observed_behavior: "Observed implementation returns a duplicate charge.",
      question: "Which source is authoritative?", source_passages: [ "Payment policy §2" ],
      check_limitations: [ "No production traffic replay" ], options: [ { "choice" => "clarify policy" } ],
      owner_actions: [ "request repair" ]
    )

    finding.defer!(reason: "Awaiting owner review")
    detail = described_class.call(finding:)

    expect(finding.resolved_at).to be_nil
    expect(detail).to include(:source_passages, :claims, :observed_behavior, :check_limitations, :options, :owner_actions)
    expect(detail.fetch(:deferred)).to be(true)
  end
end
