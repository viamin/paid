# frozen_string_literal: true

require "rails_helper"

# @spec AUTO-MERGE-010
RSpec.describe ConflictRepairs::AssessScope do
  before { configure_llm_routing(project: agent_run.project) }
  after { Current.user = nil }

  let(:agent_run) { create(:agent_run, :running, custom_prompt: "Resolve the merge conflict without broadening the PR") }
  let(:base_comparison) { comparison("docs/base.md") }
  let(:result_comparison) { comparison("docs/base.md", "app/models/provider.rb") }

  it "approves a complete in-scope assessment" do
    allow_assessment(approved: true, base_imported_paths: [ "docs/base.md" ], repair_authored_paths: [ "app/models/provider.rb" ])

    result = described_class.call(agent_run:, base_comparison:, result_comparison:)

    expect(result).to have_attributes(
      status: "approved",
      base_imported_paths: [ "docs/base.md" ],
      repair_authored_paths: [ "app/models/provider.rb" ]
    )
  end

  it "preserves an out-of-scope assessment as rejected" do
    allow_assessment(approved: false, base_imported_paths: [ "docs/base.md" ], repair_authored_paths: [ "app/models/provider.rb" ])

    result = described_class.call(agent_run:, base_comparison:, result_comparison:)

    expect(result).to have_attributes(status: "rejected", explanation: "Assessment explanation")
  end

  it "fails closed before assessment when a comparison can be truncated" do
    comparison_at_limit = comparison(*(1..described_class::MAX_COMPARE_FILES).map { |number| "app/file_#{number}.rb" })
    expect(AgentHarness.conductor).not_to receive(:execute_direct)

    result = described_class.call(agent_run:, base_comparison: comparison_at_limit, result_comparison:)

    expect(result).to have_attributes(status: "unavailable", explanation: "Repair comparison may be truncated")
  end

  it "fails closed when assessment paths omit a changed result path" do
    allow_assessment(approved: true, base_imported_paths: [ "docs/base.md" ], repair_authored_paths: [])

    result = described_class.call(agent_run:, base_comparison:, result_comparison:)

    expect(result).to have_attributes(status: "unavailable", explanation: "Scope assessment returned an invalid response")
  end

  it "fails closed when assessment marks a non-import as a base path" do
    allow_assessment(approved: true, base_imported_paths: [ "docs/base.md", "app/models/provider.rb" ], repair_authored_paths: [])

    result = described_class.call(agent_run:, base_comparison:, result_comparison:)

    expect(result).to have_attributes(status: "unavailable", explanation: "Scope assessment returned an invalid response")
  end

  it "fails closed for malformed JSON" do
    allow(AgentHarness.conductor).to receive(:execute_direct).and_return(response("not JSON"))

    result = described_class.call(agent_run:, base_comparison:, result_comparison:)

    expect(result).to have_attributes(status: "unavailable", explanation: "Scope assessment returned an invalid response")
  end

  it "fails closed for non-boolean approval values" do
    output = { approved: "true", base_imported_paths: [ "docs/base.md" ], repair_authored_paths: [ "app/models/provider.rb" ] }.to_json
    allow(AgentHarness.conductor).to receive(:execute_direct).and_return(response(output))

    result = described_class.call(agent_run:, base_comparison:, result_comparison:)

    expect(result).to have_attributes(status: "unavailable", explanation: "Scope assessment returned an invalid response")
  end

  it "fails closed when the harness does not complete the assessment" do
    allow(AgentHarness.conductor).to receive(:execute_direct).and_return(instance_double(AgentHarness::Response, success?: false))

    result = described_class.call(agent_run:, base_comparison:, result_comparison:)

    expect(result).to have_attributes(status: "unavailable", explanation: "Scope assessment did not complete")
  end

  it "fails closed when the harness raises an error" do
    allow(AgentHarness.conductor).to receive(:execute_direct).and_raise(AgentHarness::Error, "provider timeout")

    result = described_class.call(agent_run:, base_comparison:, result_comparison:)

    expect(result).to have_attributes(status: "unavailable", explanation: "Scope assessment was unavailable")
  end

  private

  def comparison(*paths)
    { files: paths.map { |path| { filename: path, patch: "@@ changed" } } }
  end

  def allow_assessment(approved:, base_imported_paths:, repair_authored_paths:)
    output = {
      approved:,
      explanation: "Assessment explanation",
      base_imported_paths:,
      repair_authored_paths:
    }.to_json
    allow(AgentHarness.conductor).to receive(:execute_direct).and_return(response(output))
  end

  def response(output)
    instance_double(AgentHarness::Response, success?: true, output:)
  end
end
