# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::UnmappedMaterial do
  let(:response_class) do
    Class.new(Struct.new(:output)) do
      def success? = true
    end
  end

  def command_runner(scope_output:, cat_output: "", exit_code: 0)
    lambda do |*command|
      next [ scope_output, exit_code ] if command.first == "git"

      [ cat_output, 0 ]
    end
  end

  def semantic_llm(payload)
    ->(prompt:, agent_run:, timeout:) { response_class.new(payload.to_json) }
  end

  def scoped_obligation(project:)
    obligation = create(:layered_verification_obligation, project:)
    obligation.correspondence_claims.create!(
      claim_type: "business_to_model", source_reference: "docs/intent/payments/payment-specs.md#L3",
      target_reference: "app/models/payment.rb", abstraction_boundaries: "Text maps to API surface.",
      assumptions: "Single-currency checkout."
    )
    obligation
  end

  # @spec LAYERED-VERIFY-009
  it "reports scope files no correspondence claim references" do
    project = create(:project)
    obligation = scoped_obligation(project:)
    run = create(:agent_run, goal: "layered_verification_audit")

    discovery = described_class.call(obligation:, agent_run: run,
      command_runner: command_runner(scope_output: "docs/intent/payments/payment-specs.md\ndocs/intent/payments/unmapped-spec.md\n"),
      llm: semantic_llm("unmapped" => []))

    expect(discovery.material).to eq([ "docs/intent/payments/unmapped-spec.md" ])
    expect(discovery.limitations).to be_empty
  end

  # @spec LAYERED-VERIFY-009
  it "merges the bounded semantic read-through for material a structural diff cannot detect" do
    project = create(:project)
    obligation = scoped_obligation(project:)
    run = create(:agent_run, goal: "layered_verification_audit")

    discovery = described_class.call(obligation:, agent_run: run,
      command_runner: command_runner(scope_output: "docs/intent/payments/payment-specs.md\n", cat_output: "Process refunds within 30 days."),
      llm: semantic_llm("unmapped" => [ "docs/intent/payments/payment-specs.md#refund-clause" ]))

    expect(discovery.material).to contain_exactly("docs/intent/payments/payment-specs.md#refund-clause")
  end

  it "keeps structural findings when the semantic read-through fails or returns invalid JSON" do
    project = create(:project)
    obligation = scoped_obligation(project:)
    run = create(:agent_run, goal: "layered_verification_audit")
    failing = ->(prompt:, agent_run:, timeout:) { raise AgentHarness::ConfigurationError, "no runner" }
    invalid = ->(prompt:, agent_run:, timeout:) { response_class.new("not json") }

    [ failing, invalid ].each do |llm|
      discovery = described_class.call(obligation:, agent_run: run,
        command_runner: command_runner(scope_output: "docs/intent/payments/unmapped-spec.md\n"), llm: llm)

      expect(discovery.material).to eq([ "docs/intent/payments/unmapped-spec.md" ])
    end
  end

  it "discloses an explicit limitation instead of guessing when structural discovery cannot execute" do
    project = create(:project)
    obligation = scoped_obligation(project:)
    run = create(:agent_run, goal: "layered_verification_audit")
    failing_runner = ->(*_command) { raise Containers::Provision::ProvisionError, "Container not provisioned" }

    discovery = described_class.call(obligation:, agent_run: run, command_runner: failing_runner, llm: semantic_llm("unmapped" => []))

    expect(discovery.material).to be_empty
    expect(discovery.limitations).to include(a_string_matching(/Structural discovery could not execute/))
  end
end
