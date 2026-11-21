# frozen_string_literal: true

require "rails_helper"

# @spec BOUNDED-PHASE-AUTHORIZATION-006
RSpec.describe Automation::AssessBoundedScope do
  let(:authorization) { create(:bounded_delegated_action) }

  it "accepts only the bounded structured in-scope result" do
    response = instance_double("response", success?: true, output: '{"status":"in_scope","explanation":"repair matches","evidence_refs":["diff:1"]}')
    allow(Llm::Request).to receive(:call).and_return(response)

    result = described_class.call(authorization:, proposed_evidence: { "diff" => "small repair" })

    expect(result).to have_attributes(status: "in_scope", evidence_refs: [ "diff:1" ])
    expect(Llm::Request).to have_received(:call).with(hash_including(project: authorization.project, timeout: 30))
  end

  it "fails closed for unavailable or malformed harness output" do
    allow(Llm::Request).to receive(:call).and_raise(AgentHarness::TimeoutError, "late")
    expect(described_class.call(authorization:).status).to eq("unknown")

    response = instance_double("response", success?: true, output: '{"status":"in_scope"}')
    allow(Llm::Request).to receive(:call).and_return(response)
    expect(described_class.call(authorization:).status).to eq("unknown")
  end
end
