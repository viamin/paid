# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::AssessNoOutputDisposition do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :in_progress, project:, body: "Implement the requested behavior.") }
  let(:agent_run) { create(:agent_run, :completed, project:, issue:) }
  let(:payload) do
    {
      disposition: "needs_input",
      rationale: "The run identified implementation that remains undone.",
      next_action: "Approve the remaining Full LID implementation scope."
    }.to_json
  end
  let(:response) do
    text = payload
    Object.new.tap do |value|
      value.define_singleton_method(:output) { text }
      value.define_singleton_method(:success?) { true }
    end
  end

  before do
    allow(Llm::Request).to receive(:call).and_return(response)
  end

  # @spec NO-OUTPUT-ISSUE-010
  it "returns a schema-validated actionable disposition without a live provider" do
    result = described_class.call(agent_run:, diagnostic_output: "Remaining LLD, EARS, tests, and implementation need approval.")

    expect(result).to eq(
      "disposition" => "needs_input",
      "rationale" => "The run identified implementation that remains undone.",
      "next_action" => "Approve the remaining Full LID implementation scope."
    )
    expect(Llm::Request).to have_received(:call).with(
      hash_including(agent_run:, timeout: described_class::TIMEOUT, prompt: a_string_including("Return only a JSON object"),
        response_validator: kind_of(Method))
    )
  end

  # @spec NO-OUTPUT-ISSUE-010
  it "rejects a missing exact next action" do
    allow(response).to receive(:output).and_return({ disposition: "needs_input", rationale: "Work remains." }.to_json)

    expect { described_class.call(agent_run:, diagnostic_output: "proposal") }
      .to raise_error(described_class::DispositionFailure) { |error| expect(error.diagnostic).to include(category: "invalid_disposition") }
  end

  # @spec NO-OUTPUT-ISSUE-010
  it "rejects a non-object JSON response with a typed disposition failure" do
    allow(response).to receive(:output).and_return("[]")

    expect { described_class.call(agent_run:, diagnostic_output: "proposal") }
      .to raise_error(described_class::DispositionFailure) { |error| expect(error.diagnostic).to include(category: "invalid_disposition") }
  end

  # @spec NO-OUTPUT-ISSUE-010
  it "rejects a response without output with a typed disposition failure" do
    allow(Llm::Request).to receive(:call).and_return(Object.new)

    expect { described_class.call(agent_run:, diagnostic_output: "proposal") }
      .to raise_error(described_class::DispositionFailure) { |error| expect(error.diagnostic).to include(category: "invalid_disposition") }
  end

  # @spec NO-OUTPUT-ISSUE-010
  it "rejects unsuccessful responses even when their output looks valid" do
    allow(response).to receive(:success?).and_return(false)

    expect { described_class.call(agent_run:, diagnostic_output: "proposal") }
      .to raise_error(described_class::DispositionFailure) { |error| expect(error.diagnostic).to include(category: "unsuccessful_response") }
  end

  # @spec NO-OUTPUT-ISSUE-010
  it "rejects non-string rationale and next-action values" do
    allow(response).to receive(:output).and_return({ disposition: "needs_input", rationale: false, next_action: 42 }.to_json)

    expect { described_class.call(agent_run:, diagnostic_output: "proposal") }
      .to raise_error(described_class::DispositionFailure) { |error| expect(error.diagnostic).to include(category: "invalid_disposition") }
  end

  # @spec NO-OUTPUT-ISSUE-011
  it "accepts an evidence-supported closure recommendation" do
    allow(response).to receive(:output).and_return({
      disposition: "recommend_close", rationale: "The acceptance was already delivered in the linked PR.",
      next_action: "Review the linked delivery evidence and close if it is sufficient."
    }.to_json)

    expect(described_class.call(agent_run:, diagnostic_output: "Verified linked PR evidence.").fetch("disposition")).to eq("recommend_close")
  end

  # @spec NO-OUTPUT-ISSUE-010
  it "reports a typed transport failure without provider output" do
    allow(Llm::Request).to receive(:call).and_raise(AgentHarness::TimeoutError, "provider payload must not persist")

    expect { described_class.call(agent_run:, diagnostic_output: "proposal") }
      .to raise_error(described_class::DispositionFailure) { |error| expect(error.diagnostic).to eq(category: "timeout") }
  end
end
