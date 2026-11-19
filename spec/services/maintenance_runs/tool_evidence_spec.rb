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
  it "runs each analyzer recipe in its discovered package scope and records distinct evidence" do
    stub_analyzer_results
    evidence = described_class.call(run:)

    expect_execution(".", adapter("exhale").availability_command, timeout: 30)
    expect_execution(".", adapter("exhale").provision_command, timeout: 300)
    expect_execution(".", %w[bundle exec exhale --version], timeout: 30)
    expect_execution(".", %w[bundle exec exhale dry --format json], timeout: 120)
    expect_execution(".", %w[bundle exec exhale complexity --format json], timeout: 120)
    expect_execution("frontend", %w[yarn knip --version], timeout: 30)
    expect_execution("frontend", adapter("knip").availability_command, timeout: 30)
    expect_execution("frontend", adapter("knip").provision_command, timeout: 300)
    expect(evidence.fetch(:completed_checks).map { |check| check.fetch("name") })
      .to contain_exactly("exhale_dry", "exhale_complexity", "knip")
    expect(evidence.fetch(:prompt_context)).to include("exhale", "knip")
    expect(evidence.fetch(:completed_checks)).to include(
      include("name" => "exhale_dry", "output" => include("duplicates"),
        "provenance" => include("package_scope" => ".")),
      include("name" => "exhale_complexity", "output" => include("complexity")),
      include("name" => "knip", "exit_code" => 1,
        "provenance" => include("package_scope" => "frontend"))
    )
  end

  def stub_analyzer_results
    allow(run).to receive(:execute_in_execution_environment).and_return(
      result(exit_code: 0, stdout: "./Gemfile\0./frontend/package.json\0"),
      result(exit_code: 0),
      result(exit_code: 0),
      result(exit_code: 0, stdout: "exhale 1.2"), result(exit_code: 0, stdout: '{"duplicates":[]}'),
      result(exit_code: 0, stdout: '{"complexity":[]}'), result(exit_code: 0), result(exit_code: 0),
      result(exit_code: 0, stdout: "knip 5.0"),
      result(exit_code: 1, stdout: '{"unusedFiles":[]}')
    )
  end

  def expect_execution(scope, command, timeout:)
    expect(run).to have_received(:execute_in_execution_environment).with(
      [ "sh", "-lc", described_class::SCOPED_EXECUTION, "paid-analyzer", scope, *command ],
      timeout:, stream: false
    )
  end

  def adapter(name)
    described_class::ADAPTERS.find { |candidate| candidate.name == name }
  end

  # @spec MAINT-044
  it "uses a prompt-only investigation when no applicable ecosystem has a native analyzer" do
    allow(project).to receive(:effective_repo_profile).and_return("languages" => [ "python" ], "marker_files" => [])
    allow(run).to receive(:execute_in_execution_environment)

    evidence = described_class.call(run:)

    expect(run).not_to have_received(:execute_in_execution_environment)
    expect(evidence).to include(completed_checks: [], incomplete_checks: [], prompt_context: nil)
  end

  # @spec MAINT-040 MAINT-044
  it "uses prompt-only fallback when matching analyzers are not declared in locked dependencies" do
    allow(run).to receive(:execute_in_execution_environment).and_return(
      result(exit_code: 0, stdout: "./Gemfile\0./frontend/package.json\0"),
      result(exit_code: 1, stderr: "exhale is not locked"),
      result(exit_code: 1, stderr: "knip is not locked")
    )

    evidence = described_class.call(run:)

    expect(evidence).to include(completed_checks: [], incomplete_checks: [], prompt_context: nil)
  end

  # @spec MAINT-022 MAINT-040
  it "records a locked dependency install failure as incomplete coverage" do
    allow(project).to receive(:effective_repo_profile).and_return("languages" => [ "ruby" ], "marker_files" => [])
    allow(run).to receive(:execute_in_execution_environment).and_return(
      result(exit_code: 0, stdout: "./Gemfile\0"), result(exit_code: 0),
      result(exit_code: 5, stderr: "bundle install failed")
    )

    evidence = described_class.call(run:)

    expect(evidence.fetch(:completed_checks)).to be_empty
    expect(evidence.fetch(:incomplete_checks)).to contain_exactly(
      include("name" => "exhale_provision", "reason" => "dependency_install_failed",
        "exit_code" => 5, "output" => include("bundle install failed"),
        "provenance" => include("package_scope" => "."))
    )
  end

  # @spec MAINT-022 MAINT-040
  it "records a provisioned analyzer version probe failure as incomplete coverage" do
    allow(project).to receive(:effective_repo_profile).and_return("languages" => [ "ruby" ], "marker_files" => [])
    allow(run).to receive(:execute_in_execution_environment).and_return(
      result(exit_code: 0, stdout: "./Gemfile\0"), result(exit_code: 0), result(exit_code: 0),
      result(exit_code: 127, stderr: "exhale: not found")
    )

    evidence = described_class.call(run:)

    expect(evidence.fetch(:completed_checks)).to be_empty
    expect(evidence.fetch(:incomplete_checks)).to contain_exactly(
      include("name" => "exhale_version", "reason" => "version_probe_failed",
        "exit_code" => 127, "output" => include("exhale: not found"),
        "provenance" => include("package_scope" => "."))
    )
  end

  # @spec MAINT-022 MAINT-042
  it "records discovery execution failures as incomplete coverage" do
    allow(run).to receive(:execute_in_execution_environment)
      .and_raise(Containers::Provision::TimeoutError, "discovery timed out")

    evidence = described_class.call(run:)

    expect(evidence.fetch(:completed_checks)).to be_empty
    expect(evidence.fetch(:incomplete_checks)).to contain_exactly(
      include("name" => "analyzer_package_discovery", "reason" => "execution_unavailable",
        "error_class" => "Containers::Provision::TimeoutError")
    )
  end

  # @spec MAINT-042
  it "records planned package discovery as incomplete when manifests cannot be resolved" do
    allow(run).to receive(:execute_in_execution_environment).and_return(result(exit_code: 2, stderr: "find failed"))

    evidence = described_class.call(run:)

    expect(evidence.fetch(:completed_checks)).to be_empty
    expect(evidence.fetch(:incomplete_checks)).to contain_exactly(
      include("name" => "analyzer_package_discovery", "reason" => "unexpected_exit_code")
    )
  end

  # @spec MAINT-042 MAINT-044
  it "does not plan an analyzer when its matching package manifest is absent" do
    allow(run).to receive(:execute_in_execution_environment).and_return(
      result(exit_code: 0, stdout: "./Gemfile\0"),
      result(exit_code: 0),
      result(exit_code: 0),
      result(exit_code: 0, stdout: "exhale 1.2"),
      result(exit_code: 0, stdout: "{}"),
      result(exit_code: 0, stdout: "{}")
    )

    evidence = described_class.call(run:)

    expect(evidence.fetch(:completed_checks).map { |check| check.fetch("name") })
      .to contain_exactly("exhale_dry", "exhale_complexity")
    expect(evidence.fetch(:incomplete_checks)).to be_empty
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
