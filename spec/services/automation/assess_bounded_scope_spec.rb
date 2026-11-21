# frozen_string_literal: true

require "rails_helper"

# @spec BOUNDED-PHASE-AUTHORIZATION-006
RSpec.describe Automation::AssessBoundedScope do
  let(:authorization) { create(:bounded_delegated_action) }

  it "accepts only the bounded structured in-scope result" do
    response = instance_double(AgentHarness::Response, success?: true, output: '{"status":"in_scope","explanation":"repair matches","evidence_refs":["diff:1"]}')
    allow(Llm::Request).to receive(:call).and_return(response)

    result = described_class.call(authorization:, proposed_evidence: { "diff" => "small repair" })

    expect(result).to have_attributes(status: "in_scope", explanation: "repair matches", evidence_refs: [ "diff:1" ])
    expect(Llm::Request).to have_received(:call).with(hash_including(project: authorization.project, timeout: 30))
  end

  it "fails closed when the harness is unavailable" do
    allow(Llm::Request).to receive(:call).and_raise(AgentHarness::TimeoutError, "late")
    expect(described_class.call(authorization:).status).to eq("unknown")
  end

  it "fails closed when an in-scope response omits its explanation" do
    response = instance_double(AgentHarness::Response, success?: true, output: '{"status":"in_scope"}')
    allow(Llm::Request).to receive(:call).and_return(response)

    expect(described_class.call(authorization:).status).to eq("unknown")
  end

  it "fails closed when the explanation is not a bounded string" do
    response = instance_double(AgentHarness::Response, success?: true, output: { status: "in_scope", explanation: 1,
      evidence_refs: [] }.to_json)
    allow(Llm::Request).to receive(:call).and_return(response)
    expect(described_class.call(authorization:).status).to eq("unknown")

    response = instance_double(AgentHarness::Response, success?: true, output: { status: "in_scope", explanation: "x" * 1_001,
      evidence_refs: [] }.to_json)
    allow(Llm::Request).to receive(:call).and_return(response)
    expect(described_class.call(authorization:).status).to eq("unknown")
  end
end
