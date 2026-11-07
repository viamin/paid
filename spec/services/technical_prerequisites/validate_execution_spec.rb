# frozen_string_literal: true

require "rails_helper"

RSpec.describe TechnicalPrerequisites::ValidateExecution do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project:) }
  let(:source_run) { create(:agent_run, :completed, project:, issue:) }
  let(:agent_run) do
    create(:agent_run, :queued, project:, issue:, base_commit_sha: "a" * 40,
      branch_name: "prerequisite-validation-abc", external_metadata: {
        TechnicalPrerequisites::RECIPE_KEY => { "source_run_id" => source_run.id }
      })
  end
  let(:execution_runner) do
    instance_double(ExecutionRunners::Base,
      provision_mcp_servers: {}, cleanup_mcp_servers: nil, provision_browser_container: nil)
  end
  let(:execution_environment) { instance_double(Containers::Provision) }
  let(:git_operations) do
    instance_double(Containers::GitOperations, clone_and_checkout_pinned_commit: "a" * 40, checkout_commit: nil, head_sha: "b" * 40)
  end
  let(:sidecar_endpoints) { [ { "name" => "analyzer", "url" => "http://analyzer:8080" } ] }

  before do
    allow(Containers::Provision).to receive(:reconnect).and_return(execution_environment)
    allow(Containers::GitOperations).to receive(:new).and_return(git_operations)
    allow(agent_run).to receive(:tool_sidecar_endpoints).and_return(sidecar_endpoints)
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "records an exact rollout approval action instead of retrying when the tool flag is off" do
    FeatureFlags.disable!(:marketplace_tool_sidecars, project:)
    AgentRun.where(id: agent_run.id).update_all(tool_sidecar_snapshot: [ { "name" => "analyzer", "image" => "example/analyzer" } ])
    agent_run.reload
    allow(Containers::BackendScheduler).to receive(:call).and_return(scheduler_result([ "remote" ]))
    allow(agent_run).to receive(:provision_execution_environment)

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result.status).to eq("unavailable")
    expect(result.setup_action).to include("marketplace_tool_sidecars")
    expect(agent_run).not_to have_received(:provision_execution_environment)
    expect(agent_run.reload.verification_result.dig("technical_prerequisite_validation", "cleanup")).to include("attempted" => false)
    expect(source_run.reload.reconciliation.dig("technical_prerequisite_evidence", "status")).to eq("unavailable")
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "uses a compatible isolated host, captures command evidence, and cleans up" do
    stub_compatible_host
    stub_provisioning
    stub_command_execution

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result).to be_success
    expect(agent_run).to have_received(:provision_execution_environment).with(container_host: "remote")
    expect(git_operations).to have_received(:clone_and_checkout_pinned_commit).with(
      branch_name: agent_run.branch_name,
      base_commit_sha: "a" * 40
    )
    expect(agent_run).to have_received(:cleanup_execution_environment).with(force: true)
    expect(agent_run.reload.verification_result.dig("technical_prerequisite_validation", "native")).to include("stdout" => "analyzer 1.0", "exit_code" => 0)
    expect(agent_run.verification_result.dig("technical_prerequisite_validation", "checkout")).to eq("b" * 40)
    expect(agent_run.verification_result.dig("technical_prerequisite_validation", "tool_endpoints"))
      .to contain_exactly(include("name" => "analyzer"))
    expect(agent_run.reload.verification_result.dig("technical_prerequisite_validation", "cleanup")).to include("completed" => true)
    expect(source_run.reload.reconciliation.dig("technical_prerequisite_evidence", "validation_run_id")).to eq(agent_run.id)
    expect(source_run.reconciliation.dig("technical_prerequisite_evidence", "cleanup")).to include("completed" => true)
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "records raw baseline/current samples and a mechanical comparison without claiming an improvement" do
    agent_run.update!(external_metadata: { TechnicalPrerequisites::RECIPE_KEY => {
      "source_run_id" => source_run.id, "performance_measurement" => {
        "baseline_commit_sha" => "b" * 40, "current_commit_sha" => "a" * 40,
        "metrics" => [ "wall_ms" ], "samples" => 2, "environment" => "isolated-linux",
        "budget_seconds" => 60
      }
    } })
    stub_compatible_host
    stub_provisioning
    allow(agent_run).to receive(:execute_in_execution_environment)
      .and_return({ stdout: '{"wall_ms":20}', stderr: "", exit_code: 0 }, { stdout: '{"wall_ms":22}', stderr: "", exit_code: 0 },
        { stdout: '{"wall_ms":12}', stderr: "", exit_code: 0 }, { stdout: '{"wall_ms":14}', stderr: "", exit_code: 0 })

    result = described_class.call(agent_run:, native_command: "bin/measure", execution_runner:)

    comparison = result.evidence.dig("performance_measurement", "comparison")
    expect([ result.status, comparison["status"] ]).to eq(%w[completed complete])
    expect(comparison.dig("metrics", "wall_ms", "baseline", "p50")).to eq(21.0)
    expect(comparison).not_to have_key("improvement")
    projected = source_run.reload.reconciliation.dig("technical_prerequisite_evidence", "performance_measurement")
    expect(projected.dig("baseline", "samples")).to be_nil
    expect(projected.fetch("baseline")).to include("sample_count" => 2, "samples_digest" => /\A[0-9a-f]{64}\z/)
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "keeps a completed sample set unknown when the linked pull request head changed during measurement" do
    pull_request = create(:issue, :pull_request, project:, github_number: source_run.pull_request_number,
      last_scanned_head_sha: "a" * 40)
    configure_performance_measurement(samples: 1)
    stub_compatible_host
    stub_provisioning
    samples = [ 20, 12 ]
    allow(agent_run).to receive(:execute_in_execution_environment) do
      value = samples.shift
      pull_request.update!(last_scanned_head_sha: "c" * 40) if samples.empty?
      { stdout: { wall_ms: value }.to_json, stderr: "", exit_code: 0 }
    end

    result = described_class.call(agent_run:, native_command: "bin/measure", execution_runner:)

    expect(result.status).to eq("failed")
    expect(result.evidence.dig("performance_measurement", "comparison")).to include(
      "status" => "unknown",
      "reason" => "The linked pull request head changed during measurement."
    )
    expect(result.evidence.dig("performance_measurement", "current", "samples")).to contain_exactly(
      include("stdout" => '{"wall_ms":12}')
    )
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "keeps successful JSON values that are not objects as unknown evidence" do
    agent_run.update!(external_metadata: { TechnicalPrerequisites::RECIPE_KEY => {
      "source_run_id" => source_run.id, "performance_measurement" => {
        "baseline_commit_sha" => "b" * 40, "current_commit_sha" => "a" * 40,
        "metrics" => [ "wall_ms" ], "samples" => 3, "environment" => "isolated-linux",
        "budget_seconds" => 60
      }
    } })
    stub_compatible_host
    stub_provisioning
    allow(agent_run).to receive(:execute_in_execution_environment)
      .and_return({ stdout: "20", stderr: "", exit_code: 0 }, { stdout: "[1,2]", stderr: "", exit_code: 0 },
        { stdout: "null", stderr: "", exit_code: 0 }, { stdout: '{"wall_ms":12}', stderr: "", exit_code: 0 },
        { stdout: '{"wall_ms":13}', stderr: "", exit_code: 0 }, { stdout: '{"wall_ms":14}', stderr: "", exit_code: 0 })

    result = described_class.call(agent_run:, native_command: "bin/measure", execution_runner:)

    expect(result.status).to eq("failed")
    expect(result.evidence.dig("performance_measurement", "comparison"))
      .to include("status" => "unknown", "reason" => "A baseline, current, or raw metric sample was unavailable.")
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "stops sampling when the shared measurement budget is exhausted and persists the partial result as unknown" do
    agent_run.update!(external_metadata: { TechnicalPrerequisites::RECIPE_KEY => {
      "source_run_id" => source_run.id, "performance_measurement" => {
        "baseline_commit_sha" => "b" * 40, "current_commit_sha" => "a" * 40,
        "metrics" => [ "wall_ms" ], "samples" => 2, "environment" => "isolated-linux",
        "budget_seconds" => 0
      }
    } })
    stub_compatible_host
    stub_provisioning
    allow(agent_run).to receive(:execute_in_execution_environment)

    result = described_class.call(agent_run:, native_command: "bin/measure", execution_runner:)

    expect(result.status).to eq("failed")
    expect(agent_run).not_to have_received(:execute_in_execution_environment)
    expect(result.evidence.dig("performance_measurement", "comparison")).to include("status" => "unknown")
    expect(result.evidence.dig("performance_measurement", "baseline", "samples")).to eq([])
    expect(agent_run.reload.verification_result.dig("technical_prerequisite_validation", "cleanup"))
      .to include("attempted" => true, "completed" => true)
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "keeps a metric missing from one otherwise successful sample unknown" do
    agent_run.update!(external_metadata: { TechnicalPrerequisites::RECIPE_KEY => {
      "source_run_id" => source_run.id, "performance_measurement" => {
        "baseline_commit_sha" => "b" * 40, "current_commit_sha" => "a" * 40,
        "metrics" => [ "wall_ms" ], "samples" => 3, "environment" => "isolated-linux",
        "budget_seconds" => 60
      }
    } })
    stub_compatible_host
    stub_provisioning
    allow(agent_run).to receive(:execute_in_execution_environment)
      .and_return({ stdout: '{"wall_ms":20}', stderr: "", exit_code: 0 }, { stdout: '{}', stderr: "", exit_code: 0 },
        { stdout: '{"wall_ms":22}', stderr: "", exit_code: 0 }, { stdout: '{"wall_ms":12}', stderr: "", exit_code: 0 },
        { stdout: '{}', stderr: "", exit_code: 0 }, { stdout: '{"wall_ms":14}', stderr: "", exit_code: 0 })

    result = described_class.call(agent_run:, native_command: "bin/measure", execution_runner:)

    expect(result.status).to eq("failed")
    expect(result.evidence.dig("performance_measurement", "comparison"))
      .to include("status" => "unknown", "reason" => "Metric wall_ms was unavailable from a complete sample set.")
    expect(result.evidence["error"]).to eq("Metric wall_ms was unavailable from a complete sample set.")
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "keeps non-finite metric samples unknown" do
    agent_run.update!(external_metadata: { TechnicalPrerequisites::RECIPE_KEY => {
      "source_run_id" => source_run.id, "performance_measurement" => {
        "baseline_commit_sha" => "b" * 40, "current_commit_sha" => "a" * 40,
        "metrics" => [ "wall_ms" ], "samples" => 1, "environment" => "isolated-linux",
        "budget_seconds" => 60
      }
    } })
    stub_compatible_host
    stub_provisioning
    allow(agent_run).to receive(:execute_in_execution_environment)
      .and_return({ stdout: '{"wall_ms":1e400}', stderr: "", exit_code: 0 },
        { stdout: '{"wall_ms":12}', stderr: "", exit_code: 0 })

    result = described_class.call(agent_run:, native_command: "bin/measure", execution_runner:)

    expect(result.status).to eq("failed")
    expect(result.evidence.dig("performance_measurement", "comparison"))
      .to include("status" => "unknown", "reason" => "Metric wall_ms was unavailable from a complete sample set.")
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "persists a partial baseline/current record as unknown when a revision checkout is unreachable" do
    agent_run.update!(external_metadata: { TechnicalPrerequisites::RECIPE_KEY => {
      "source_run_id" => source_run.id, "performance_measurement" => {
        "baseline_commit_sha" => "b" * 40, "current_commit_sha" => "a" * 40,
        "metrics" => [ "wall_ms" ], "samples" => 2, "environment" => "isolated-linux",
        "budget_seconds" => 60
      }
    } })
    stub_compatible_host
    stub_provisioning
    allow(agent_run).to receive(:execute_in_execution_environment)
      .and_return({ stdout: '{"wall_ms":20}', stderr: "", exit_code: 0 }, { stdout: '{"wall_ms":22}', stderr: "", exit_code: 0 })
    allow(git_operations).to receive(:checkout_commit).with("b" * 40)
    allow(git_operations).to receive(:checkout_commit).with("a" * 40).and_raise(Containers::GitOperations::Error, "unreachable")

    evidence = described_class.call(agent_run:, native_command: "bin/measure", execution_runner:).evidence

    expect(evidence.dig("performance_measurement", "baseline", "samples").size).to eq(2)
    expect(evidence.dig("performance_measurement", "current"))
      .to include("revision" => "a" * 40, "samples" => [], "error" => "unreachable")
    expect(evidence.dig("performance_measurement", "comparison")).to include("status" => "unknown")
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "provisions the isolated browser sidecar for a browser-visible measurement" do
    stub_browser_measurement

    result = described_class.call(agent_run:, native_command: "bin/measure", execution_runner:)

    expect(result).to be_success
    expect(Containers::BackendScheduler).to have_received(:call).with(
      agent_run:, additional_capabilities: [ :browser_sidecar ]
    )
    expect(execution_runner).to have_received(:provision_browser_container).with(
      agent_run:, network: Containers::Provision.network_for(agent_run:), logger: Rails.logger
    )
    expect(result.evidence.fetch("browser")).to include(
      "container_id" => "browser-1", "cdp_url" => "ws://paid-screenshot-browser:3000"
    )
    expect(agent_run).to have_received(:execute_in_execution_environment).with(
      "bin/measure", timeout: kind_of(ActiveSupport::Duration), stream: false,
      env: hash_including("PAID_BROWSER_CDP_URL" => "ws://paid-screenshot-browser:3000")
    ).at_least(:once)
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "keeps browser-visible measurement unavailable when project verification is disabled" do
    stub_browser_measurement
    project.update!(screenshot_settings: { "verification_enabled" => false })

    result = described_class.call(agent_run:, native_command: "bin/measure", execution_runner:)

    expect(result.status).to eq("unavailable")
    expect(result.setup_action).to include("Enable browser verification")
    expect(execution_runner).not_to have_received(:provision_browser_container)
    expect(agent_run).not_to have_received(:provision_execution_environment)
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "does not provision when the running validation is cancelled during capability inspection" do
    agent_run.update!(status: "running")
    allow(Containers::BackendScheduler).to receive(:call) do
      agent_run.update!(status: "cancelled", completed_at: Time.current)
      scheduler_result([ "remote" ])
    end
    FeatureFlags.enable!(:marketplace_tool_sidecars, project:)
    allow(agent_run).to receive(:provision_execution_environment)

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result.status).to eq("cancelled")
    expect(agent_run).not_to have_received(:provision_execution_environment)
    expect(agent_run.reload.status).to eq("cancelled")
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "cleans up without executing when the running validation is cancelled before command execution" do
    agent_run.update!(status: "running")
    stub_compatible_host
    stub_provisioning
    allow(execution_runner).to receive(:provision_mcp_servers) do
      agent_run.update!(status: "cancelled", completed_at: Time.current)
    end
    allow(agent_run).to receive(:execute_in_execution_environment)

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result.status).to eq("cancelled")
    expect(agent_run).not_to have_received(:execute_in_execution_environment)
    expect(execution_runner).to have_received(:cleanup_mcp_servers).with(agent_run:)
    expect(agent_run).to have_received(:cleanup_execution_environment).with(force: true)
    expect(agent_run.reload.status).to eq("cancelled")
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "records a flat resolved image identity and digest" do
    agent_run.record_runtime_image_selection!(
      "requested_image" => "paid-agent:latest",
      "resolved_image" => "registry.example/paid-agent@sha256:abc",
      "digest" => "sha256:abc"
    )
    stub_compatible_host
    stub_provisioning
    stub_command_execution

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result.evidence).to include(
      "image" => "registry.example/paid-agent@sha256:abc",
      "image_digest" => "sha256:abc"
    )
    expect(result.evidence.fetch("image_selection")).to include("resolved_image" => "registry.example/paid-agent@sha256:abc")
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "plans the inspected host so the container lands on the host the capability decision approved" do
    stub_compatible_host
    stub_provisioning
    allow(agent_run).to receive(:execute_in_execution_environment).and_return(stdout: "", stderr: "", exit_code: 0)

    described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(agent_run.reload.external_metadata["planned_container_host"]).to eq("remote")
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "provisions and cleans up sidecars through the selected execution runner" do
    stub_compatible_host
    stub_provisioning

    expect(execution_runner).to receive(:provision_mcp_servers).with(
      agent_run:,
      network: Containers::Provision.network_for(agent_run:)
    ).ordered
    expect(agent_run).to receive(:execute_in_execution_environment).with(
      [ "analyzer", "--version" ],
      stream: false,
      timeout: described_class::COMMAND_TIMEOUT,
      env: { "PAID_TOOL_SIDECAR_ENDPOINTS" => '[{"name":"analyzer","url":"http://analyzer:8080"}]' }
    ).ordered.and_return(stdout: "analyzer 1.0", stderr: "", exit_code: 0)

    expect(execution_runner).to receive(:cleanup_mcp_servers).with(agent_run:).ordered

    described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "passes a reviewed shell recipe through unchanged" do
    stub_compatible_host
    stub_provisioning
    command = "bundle exec rubocop | tee rubocop.log"
    expect(agent_run).to receive(:execute_in_execution_environment).with(
      command,
      timeout: described_class::COMMAND_TIMEOUT,
      stream: false,
      env: { "PAID_TOOL_SIDECAR_ENDPOINTS" => '[{"name":"analyzer","url":"http://analyzer:8080"}]' }
    ).and_return(stdout: "", stderr: "", exit_code: 0)

    described_class.call(agent_run:, native_command: command, execution_runner:)
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "records the attached tool identity and endpoint for a native-plus-sidecar validation" do
    AgentRun.where(id: agent_run.id).update_all(
      tool_sidecar_snapshot: [ { "name" => "analyzer", "image" => "example/analyzer", "version" => "1.2.3" } ]
    )
    agent_run.reload
    stub_compatible_host
    stub_provisioning
    allow(agent_run).to receive_messages(
      execute_in_execution_environment: { stdout: "analyzer 1.0", stderr: "", exit_code: 0 },
      tool_sidecar_container_ids: [ "container-1" ]
    )

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result).to be_success
    expect(result.evidence["tool_identity"]).to contain_exactly(include("name" => "analyzer", "image" => "example/analyzer"))
    expect(result.evidence["tool_sidecars"]).to eq([ "container-1" ])
    expect(result.evidence["tool_endpoints"]).to contain_exactly(include("url" => "http://analyzer:8080"))
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "records the provisioner's rejection when the attached tool image is not allowed" do
    AgentRun.where(id: agent_run.id).update_all(
      tool_sidecar_snapshot: [ { "name" => "analyzer", "image" => "example/denied" } ]
    )
    agent_run.reload
    stub_compatible_host
    stub_provisioning
    allow(execution_runner).to receive(:provision_mcp_servers).and_raise(
      Containers::McpProvisioner::Error, 'Image "example/denied" is not in the allowed service images list for this account'
    )

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result.status).to eq("failed")
    expect(result.evidence["error"]).to include("is not in the allowed service images list")
    expect(result.evidence["checkout"]).to eq("b" * 40)
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "cleans up resources when provisioning fails before it records a container" do
    stub_compatible_host
    allow(agent_run).to receive(:provision_execution_environment)
      .and_raise(Containers::Provision::Error, "image pull failed")
    allow(agent_run).to receive(:cleanup_execution_environment)

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result.status).to eq("failed")
    expect(agent_run).to have_received(:cleanup_execution_environment).with(force: true)
    expect(agent_run.reload.verification_result.dig("technical_prerequisite_validation", "cleanup"))
      .to include("attempted" => true, "completed" => true)
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "records a failed outcome with the analyzer output when the command exits non-zero" do
    stub_compatible_host
    stub_provisioning
    allow(agent_run).to receive(:execute_in_execution_environment).and_return(stdout: "boom", stderr: "missing tool", exit_code: 3)

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result.status).to eq("failed")
    expect(result.evidence["native"]).to include("stdout" => "boom", "stderr" => "missing tool", "exit_code" => 3)
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "records no compatible backend as unavailable without running an unchanged validation" do
    allow(Containers::BackendScheduler).to receive(:call).and_return(scheduler_result([]))
    allow(agent_run).to receive(:provision_execution_environment)

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result.status).to eq("unavailable")
    expect(result.setup_action).to eq("Configure or restore a compatible execution backend for this project.")
    expect(agent_run).not_to have_received(:provision_execution_environment)
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "preserves a capability-requirements failure as the unavailable setup action" do
    error = 'Runtime image reference "retired" is deprecated'
    allow(Containers::BackendScheduler).to receive(:call).and_return(scheduler_result([], requirements_error: error))
    allow(agent_run).to receive(:provision_execution_environment)

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result.status).to eq("unavailable")
    expect(result.setup_action).to eq("Resolve execution requirements: #{error}")
    expect(agent_run.reload.verification_result.dig(
      "technical_prerequisite_validation", "inspection", "requirements_error"
    )).to eq(error)
    expect(agent_run).not_to have_received(:provision_execution_environment)
  end

  def stub_compatible_host(hosts = [ "remote" ])
    allow(Containers::BackendScheduler).to receive(:call).and_return(scheduler_result(hosts))
    FeatureFlags.enable!(:marketplace_tool_sidecars, project:)
  end

  def configure_performance_measurement(samples:)
    agent_run.update!(external_metadata: { TechnicalPrerequisites::RECIPE_KEY => {
      "source_run_id" => source_run.id, "performance_measurement" => {
        "baseline_commit_sha" => "b" * 40, "current_commit_sha" => "a" * 40,
        "metrics" => [ "wall_ms" ], "samples" => samples, "environment" => "isolated-linux",
        "budget_seconds" => 60
      }
    } })
  end

  def stub_browser_measurement
    project.update!(screenshot_settings: { "verification_enabled" => true })
    agent_run.update!(external_metadata: { TechnicalPrerequisites::RECIPE_KEY => {
      "source_run_id" => source_run.id, "performance_measurement" => {
        "baseline_commit_sha" => "b" * 40, "current_commit_sha" => "a" * 40,
        "metrics" => [ "wall_ms" ], "samples" => 2, "environment" => "browser-visible",
        "budget_seconds" => 60, "requires_browser" => true
      }
    } })
    stub_compatible_host
    stub_provisioning
    browser = instance_double(AgentRuns::Verification::Result,
      container_id: "browser-1", cdp_url: "ws://paid-screenshot-browser:3000")
    allow(execution_runner).to receive(:provision_browser_container).and_return(browser)
    allow(agent_run).to receive(:execute_in_execution_environment)
      .and_return({ stdout: '{"wall_ms":20}', stderr: "", exit_code: 0 }, { stdout: '{"wall_ms":22}', stderr: "", exit_code: 0 },
        { stdout: '{"wall_ms":12}', stderr: "", exit_code: 0 }, { stdout: '{"wall_ms":14}', stderr: "", exit_code: 0 })
  end

  def stub_command_execution(stdout: "analyzer 1.0", stderr: "", exit_code: 0)
    allow(agent_run).to receive(:execute_in_execution_environment).with(
      [ "analyzer", "--version" ],
      stream: false,
      timeout: described_class::COMMAND_TIMEOUT,
      env: { "PAID_TOOL_SIDECAR_ENDPOINTS" => '[{"name":"analyzer","url":"http://analyzer:8080"}]' }
    ).and_return(stdout:, stderr:, exit_code:)
  end

  def stub_provisioning
    performance_recipe = agent_run.external_metadata.dig(TechnicalPrerequisites::RECIPE_KEY, "performance_measurement")
    if performance_recipe
      project.issues.find_by(github_number: source_run.pull_request_number, is_pull_request: true) ||
        create(:issue, :pull_request, project:, github_number: source_run.pull_request_number,
          last_scanned_head_sha: performance_recipe.fetch("current_commit_sha"))
    end
    allow(agent_run).to receive_messages(
      provision_execution_environment: nil,
      cleanup_execution_environment: nil
    )
  end

  def scheduler_result(hosts, requirements_error: nil)
    Containers::BackendScheduler::Result.new(
      candidate_hosts: hosts,
      requirements_error:,
      compatibility_failures: {},
      health_failures: {}
    )
  end
end
