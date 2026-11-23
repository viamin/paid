# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperationalSupervisor::Analyze do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:response_class) { Data.define(:success?, :output, :model) }
  let(:snapshot) do
    create(:supervisor_snapshot, account:, included_project_ids: [ project.id ],
      digest: { "schema_version" => 1, "metrics" => [
        { "name" => "queue_starvation", "status" => "available", "value" => 3 }
      ] })
  end
  let(:llm) { class_double(Llm::Request) }
  let(:response) { response_class.new(true, response_output, "model-2026-11") }
  let(:response_output) { response_fixture(project.id) }

  around do |example|
    FeatureFlags.enable!(:operational_supervisor, project:)
    example.run
  ensure
    FeatureFlags.disable!(:operational_supervisor, project:)
  end

  it "sends only the sanitized snapshot to agent_harness and retains response identities" do # @spec OPERATIONAL-SUPERVISOR-001, OPERATIONAL-SUPERVISOR-005
    captured = nil
    allow(llm).to receive(:call) do |**arguments|
      captured = arguments
      response
    end

    result = described_class.call(account:, snapshot:, llm:)

    expect(captured).to include(account:, timeout: described_class::TIMEOUT)
    expect(captured.fetch(:response_validator)).to respond_to(:call)
    expect(captured.fetch(:prompt)).to include(snapshot.digest.to_json)
    expect(captured.fetch(:prompt)).not_to include("customer stack trace", "sk-super-secret-token", "repository-authored body")
    expect(result.model_identifier).to eq("model-2026-11")
    expect(result.prompt_identifier).to eq(described_class::PROMPT_IDENTIFIER)
    expect(result.policy_identifier).to eq(described_class::POLICY_IDENTIFIER)
  end

  it "accepts a catalog recommendation for snapshot-member targets" do # @spec OPERATIONAL-SUPERVISOR-005
    allow(llm).to receive(:call).and_return(response)

    result = described_class.call(account:, snapshot:, llm:)

    expect(result.findings).to contain_exactly(
      have_attributes(category: "queue_starvation", severity: "warning", affected_project_ids: [ project.id ],
        target_ids: { "project_ids" => [ project.id ] }, evidence: { "metric_names" => [ "queue_starvation" ] },
        recommendation: "inspect_queue_capacity")
    )
  end

  it "fails closed without incident or audit mutation for malformed, unknown, or unauthorized output" do # @spec OPERATIONAL-SUPERVISOR-006
    invalid_outputs = [
      [ "not json", "invalid_json" ],
      [ response_fixture(project.id).sub("inspect_queue_capacity", "invent_a_mitigation"), "invalid_response" ],
      [ response_fixture(project.id).sub(project.id.to_s, (project.id + 999).to_s), "invalid_response" ],
      [ file_fixture("operational_supervisor/forbidden_analysis_response.json").read.sub("101", project.id.to_s), "invalid_response" ]
    ]

    invalid_outputs.each do |output, reason|
      allow(llm).to receive(:call).and_return(response_class.new(true, output, "model-2026-11"))

      expect(Rails.logger).to receive(:warn).with(
        message: "operational_supervisor.analysis_rejected", account_id: account.id, snapshot_id: snapshot.id,
        reason:
      )
      expect { described_class.call(account:, snapshot:, llm:) }.to raise_error(described_class::InvalidResponse)
      expect(SupervisorIncident.count).to eq(0)
      expect(SupervisorIncidentAudit.count).to eq(0)
    end
  end

  it "supplies the same strict contract to Llm::Request for fallback routing" do # @spec OPERATIONAL-SUPERVISOR-005, OPERATIONAL-SUPERVISOR-006
    validator = nil
    allow(llm).to receive(:call) do |**arguments|
      validator = arguments.fetch(:response_validator)
      response
    end

    described_class.call(account:, snapshot:, llm:)

    expect(validator.call(response)).to be(true)
    expect(validator.call(response_class.new(true, "{}", "model-2026-11"))).to be(false)
    expect(validator.call(response_class.new(true, file_fixture("operational_supervisor/forbidden_analysis_response.json").read, "model-2026-11"))).to be(false)
    expect(validator.call(response_class.new(true, response_output, ""))).to be(false)
  end

  it "rejects a snapshot that includes a project disabled since capture without contacting agent_harness" do # @spec OPERATIONAL-SUPERVISOR-005, OPERATIONAL-SUPERVISOR-006
    FeatureFlags.disable!(:operational_supervisor, project:)
    expect(llm).not_to receive(:call)

    expect(Rails.logger).to receive(:warn).with(
      message: "operational_supervisor.analysis_rejected", account_id: account.id, snapshot_id: snapshot.id,
      reason: "invalid_response"
    )
    expect { described_class.call(account:, snapshot:, llm:) }.to raise_error(described_class::InvalidResponse)
  end

  private

  def response_fixture(project_id)
    file_fixture("operational_supervisor/analysis_response.json").read.gsub("101", project_id.to_s)
  end
end
