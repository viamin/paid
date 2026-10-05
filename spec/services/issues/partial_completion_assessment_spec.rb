# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::PartialCompletionAssessment do
  let(:issue) { create(:issue) }

  it "persists only the harness's structured semantic partial verdict" do # @spec AUTO-PICK-QUEUE-012
    response = instance_double(AgentHarness::Response, success?: true,
      output: '{"partial":true,"reason":"The linked migration is still required."}')
    allow(AgentHarness).to receive(:send_message).and_return(response)

    result = described_class.call(issue: issue)

    expect(result).to have_attributes(partial: true, reason: "The linked migration is still required.")
  end

  it "fails closed when the harness returns malformed output" do # @spec AUTO-PICK-QUEUE-012
    response = instance_double(AgentHarness::Response, success?: true, output: "not json")
    allow(AgentHarness).to receive(:send_message).and_return(response)

    expect(described_class.call(issue: issue)).to be_nil
  end
end
