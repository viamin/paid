# frozen_string_literal: true

require "rails_helper"

RSpec.describe MaintenanceRuns::ToolEvidence do
  let(:project) { instance_double(Project, effective_repo_profile: profile) }
  let(:run) do
    instance_double(AgentRun, project:, maintenance_objective: "unnecessary_code",
      tool_sidecar_snapshot: sidecars, tool_sidecar_endpoints: endpoints)
  end
  let(:profile) { { "languages" => languages, "marker_files" => markers } }
  let(:languages) { [ "ruby", "typescript" ] }
  let(:markers) { [ "Gemfile", "package.json" ] }
  let(:sidecars) { [] }
  let(:endpoints) { [] }

  def result(exit_code:, stdout: "", stderr: "")
    Containers::Provision::Result.success(stdout:, stderr:, exit_code:)
  end

  # @spec MAINT-040 MAINT-042 MAINT-043
  it "runs the Ruby and JS analyzers in the run execution environment and records their provenance" do
    allow(run).to receive(:execute_in_execution_environment).and_return(
      result(exit_code: 0, stdout: "exhale 1.2"),
      result(exit_code: 1, stdout: '{"issues":[]}'),
      result(exit_code: 0, stdout: "knip 5.0"),
      result(exit_code: 1, stdout: '{"unusedFiles":[]}')
    )

    evidence = described_class.call(run:)

    expect(run).to have_received(:execute_in_execution_environment).with(
      %w[bundle exec exhale --version], timeout: 30, stream: false
    )
    expect(run).to have_received(:execute_in_execution_environment).with(
      %w[yarn knip --version], timeout: 30, stream: false
    )
    expect(evidence.fetch(:completed_checks).map { |check| check.fetch("name") }).to contain_exactly("exhale", "knip")
    expect(evidence.fetch(:prompt_context)).to include("Exhale", "Knip")
    expect(evidence.fetch(:completed_checks)).to include(include("name" => "knip", "exit_code" => 1))
  end

  # @spec MAINT-044
  it "uses a prompt-only investigation when no applicable ecosystem has a native analyzer" do
    allow(project).to receive(:effective_repo_profile).and_return("languages" => [ "python" ], "marker_files" => [])
    allow(run).to receive(:execute_in_execution_environment)

    evidence = described_class.call(run:)

    expect(run).not_to have_received(:execute_in_execution_environment)
    expect(evidence).to include(completed_checks: [], incomplete_checks: [], prompt_context: nil)
  end

  # @spec MAINT-041 MAINT-045
  it "exposes existing marketplace sidecar endpoints as advisory evidence without creating a matcher or gate" do
    allow(project).to receive(:effective_repo_profile).and_return("languages" => [], "marker_files" => [])
    allow(run).to receive(:execute_in_execution_environment)
    sidecars.replace([ { "name" => "semantic-search", "image" => "example/search:2", "port" => 8080 } ])
    endpoints.replace([ { "name" => "semantic-search", "url" => "http://semantic-search:8080" } ])

    evidence = described_class.call(run:)

    expect(evidence.fetch(:prompt_context)).to include("semantic-search", "advisory")
    expect(evidence.fetch(:completed_checks)).to include(include("name" => "marketplace_tool_attachments"))
  end
end
