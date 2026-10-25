# frozen_string_literal: true

# frozen_string: true

require "rails_helper"

RSpec.describe Prerequisites::ExecuteValidation do # @spec PREREQ-EVIDENCE-003 @spec PREREQ-EVIDENCE-004
  # @spec PREREQ-EVIDENCE-005 @spec PREREQ-EVIDENCE-006 @spec PREREQ-EVIDENCE-008
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }
  let(:issue) { create(:issue, project: project, github_state: "open") }
  let(:validation) do
    create(:prerequisite_validation, account: account, project: project, issue: issue,
      requested_by: user, status: "pending", include_tool_sidecar: true)
  end
  let(:run) do
    create(:agent_run, project: project, issue: issue, agent_type: "internal_agent",
      goal: PrerequisiteValidation::RUN_GOAL, synthetic: true, status: "running")
  end
  let(:tool_entry_identity) do
    { "id" => 4242, "name" => "echo-tool", "version" => 3, "version_id" => 99, "image" => "example/echo:1" }
  end
  let(:endpoints) do
    [ { "name" => "echo-tool", "hostname" => "paid-tool-echo-tool-run1", "port" => 8080, "url" => "http://paid-tool-echo-tool-run1:8080/" } ]
  end
  let(:git_operations_class) do
    Class.new do
      def initialize(container_service:, agent_run:)
        @agent_run = agent_run
      end

      def clone_and_setup_branch
        @agent_run.update!(base_commit_sha: "abc123def456", branch_name: "paid/validation-1", worktree_path: "/workspace")
      end
    end
  end
  # In-memory provisioner double standing in for the RDR-073 McpProvisioner
  # tool arm: records endpoint/container state exactly as the real contract
  # persists it on the run, and clears it on cleanup.
  let(:provisioner_class) do
    Class.new do
      def provision(run)
        run.update!(
          tool_sidecar_endpoints: [ { "name" => "echo-tool", "hostname" => "paid-tool-echo-tool-run1", "port" => 8080,
                                      "url" => "http://paid-tool-echo-tool-run1:8080/" } ],
          tool_sidecar_container_ids: %w[sidecar-1]
        )
      end

      def cleanup(run)
        run.update!(tool_sidecar_endpoints: [], tool_sidecar_container_ids: [])
      end
    end
  end

  def report(healthy: true, flag: true, entry: tool_entry_identity, image_allowed: true, hosts: nil)
    hosts ||= { "local" => { host: "local", healthy: healthy, checked_at: Time.current,
                             failing_check: healthy ? nil : "docker_ping",
                             remediation_hint: healthy ? nil : "Ensure Docker is running and reachable on local.",
                             checks: [] } }
    healthy_ids = hosts.select { |_host, payload| payload[:healthy] }.keys
    host_blockers = hosts.filter_map do |host, payload|
      next if payload[:healthy]

      {
        "check" => Prerequisites::CapabilityReport::NO_HEALTHY_HOST_CHECK,
        "reason" => "Execution host #{host} is not ready: #{payload[:failing_check]} — #{payload[:remediation_hint]}",
        "authorized_action" => payload[:remediation_hint]
      }
    end
    Prerequisites::CapabilityReport::Report.new(
      hosts: hosts,
      healthy_host_identifiers: healthy_ids,
      compatible_host: healthy_ids.first,
      tool_sidecars_enabled: flag,
      tool_sidecar_authorized_action: flag ? nil : Prerequisites::CapabilityReport::FLAG_ENABLE_ACTION,
      allowlisted_images: %w[example/echo:1],
      tool_entry: entry,
      tool_image: entry&.dig("image"),
      tool_image_allowed: entry ? image_allowed : false,
      tool_image_authorized_action: image_allowed ? nil : "Add the image to allowed service images.",
      host_blockers: host_blockers,
      checked_at: Time.current,
      scope_digest: "digest"
    )
  end


  def stub_execution_environment!(native_result: Containers::Provision::Result.success(stdout: "scc 3.7.0\nabc123\n", stderr: "", exit_code: 0))
    allow(AgentRun).to receive(:create!).and_return(run)
    allow(run).to receive_messages(provision_execution_environment: true, cleanup_execution_environment: true, execute_in_execution_environment: native_result)
    allow(MarketplaceEntries::AttachToRun).to receive(:call)
  end

  def native_result(stdout: "scc 3.7.0\n", stderr: "", exit_code: 0)
    result = Containers::Provision::Result.new(success: exit_code.zero?, data: { stdout: stdout, stderr: stderr, exit_code: exit_code })
    result
  end

  def execute!(capability_report)
    described_class.call(validation, capability_report: capability_report, provisioner_class: provisioner_class,
      git_operations_class: git_operations_class)
    validation.reload
  end

  def expect_successful_evidence
    checks = validation.result.fetch("checks")
    expect(checks.fetch("native_analyzer")).to include("status" => "succeeded", "exit_code" => 0, "stdout" => a_string_including("scc 3.7.0"), "command" => PrerequisiteValidation::DEFAULT_ANALYZER_COMMAND)
    expect(checks.fetch("tool_sidecar")).to include("status" => "succeeded", "exit_code" => 0, "entry" => tool_entry_identity, "endpoints" => endpoints)
    expect(checks.dig("tool_sidecar", "stdout")).to include("ok")
    expect(checks.fetch("cleanup")).to include("status" => "succeeded", "sidecars" => { "cleaned" => true, "container_ids" => %w[sidecar-1] }, "run_container" => { "cleaned" => true, "container_id" => nil })
  end

  before do
    stub_execution_environment!
  end

  describe "a successful native-plus-sidecar lifecycle" do
    it "captures stdout/stderr/exit status, identity, endpoint response, and cleanup evidence" do
      allow(run).to receive(:execute_in_execution_environment).with("scc --version && git rev-parse HEAD", anything).and_return(native_result)
      allow(run).to receive(:execute_in_execution_environment).with(/curl -fsS/, anything).and_return(native_result(stdout: %({"status":"ok"})))

      execute!(report)

      expect(validation.status).to eq("succeeded")
      expect_successful_evidence
      expect(validation.result["checkout"]["base_commit_sha"]).to eq("abc123def456")
      expect(validation.result["requested_checks"]).to eq(%w[native_analyzer tool_sidecar])
    end

    it "runs the analyzer and endpoint probe only through execute_in_execution_environment" do
      allow(run).to receive(:execute_in_execution_environment).and_return(native_result)

      execute!(report)

      expect(run).to have_received(:execute_in_execution_environment).with("scc --version && git rev-parse HEAD", hash_including(stream: false)).once
      expect(run).to have_received(:execute_in_execution_environment).with(/curl -fsS --max-time 30/, hash_including(stream: false)).once
      expect(MarketplaceEntries::AttachToRun).to have_received(:call).with(agent_run: run, manual_entry_ids: [ 4242 ])
    end

    it "records image identity from the run's image_resolved audit record" do
      ExecutionAuditEvent.record!(
        account: account, project: project, agent_run: run,
        event_name: "execution.image_resolved", actor_id: "spec",
        image_reference: "paid-agent:1.2.3", image_digest: "sha256:abc"
      )

      execute!(report)

      expect(validation.result["image"]).to eq("reference" => "paid-agent:1.2.3", "digest" => "sha256:abc")
    end

    it "links the evidence run without resolving the prerequisite notification or the issue" do
      notification = Notifications::Publish.call(
        account: account, subject: issue, source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
        severity: :error, blocking: true, title: "Evidence needed", description: "Run the native+sidecar validation."
      )

      execute!(report)

      expect(validation.agent_run_id).to eq(run.id)
      expect(notification.reload).to be_active
      expect(issue.reload.paid_state).not_to eq("completed")
      expect(run.reload.synthetic?).to be(true)
    end
  end

  describe "no compatible backend" do
    it "completes unavailable with the host remediation hints and provisions nothing" do
      allow(AgentRun).to receive(:create!)

      execute!(report(healthy: false))

      expect(validation.status).to eq("unavailable")
      expect(validation.blockers).to contain_exactly(a_hash_including(
        "check" => "execution_host",
        "authorized_action" => "Ensure Docker is running and reachable on local."
      ))
      expect(validation.agent_run_id).to be_nil
      expect(AgentRun).not_to have_received(:create!)
      expect(run).not_to have_received(:provision_execution_environment)
    end
  end

  describe "tool flag off" do
    it "blocks the sidecar check with the authorized enablement action and stays partial" do
      allow(run).to receive(:execute_in_execution_environment).and_return(native_result)

      execute!(report(flag: false))

      expect(validation.status).to eq("partial")
      expect(validation.result["checks"]["tool_sidecar"]).to include(
        "status" => "blocked",
        "authorized_action" => a_string_including("tenant_settings.features")
      )
      expect(validation.blockers).to contain_exactly(a_hash_including("check" => "tool_sidecar"))
      expect(MarketplaceEntries::AttachToRun).not_to have_received(:call)
    end
  end

  describe "denied tool image" do
    it "blocks the sidecar check with the allowlist action" do
      execute!(report(image_allowed: false))

      expect(validation.status).to eq("partial")
      expect(validation.result["checks"]["tool_sidecar"]).to include(
        "status" => "blocked",
        "authorized_action" => a_string_including("allowed service images")
      )
    end
  end

  describe "no tool entry published" do
    it "blocks the sidecar check with the publish action" do
      execute!(report(entry: nil))

      expect(validation.status).to eq("partial")
      expect(validation.result["checks"]["tool_sidecar"]).to include(
        "status" => "blocked",
        "reason" => a_string_including("No active marketplace entry")
      )
    end
  end

  describe "failed analyzer execution" do
    it "distinguishes a failed run from a successful or blocked one" do
      allow(run).to receive(:execute_in_execution_environment).and_return(native_result(stdout: "", stderr: "boom", exit_code: 1))

      execute!(report)

      expect(validation.status).to eq("failed")
      expect(validation.result["checks"]["native_analyzer"]).to include("status" => "failed", "exit_code" => 1)
    end

    it "records a provisioning failure with preserved cleanup evidence" do
      allow(run).to receive(:provision_execution_environment).and_raise(Containers::Provision::ProvisionError, "Docker error: no socket")

      execute!(report)

      expect(validation.status).to eq("failed")
      expect(validation.result["checks"]["native_analyzer"]).to include("status" => "failed", "reason" => a_string_including("no socket"))
      expect(validation.result["checks"]["cleanup"]["status"]).to eq("succeeded")
      expect(run.reload.status).to eq("failed")
    end
  end

  describe "cancellation" do
    it "preserves collected evidence, skips the remaining check, and still cleans up" do
      allow(run).to receive(:execute_in_execution_environment).and_wrap_original do |_method, *_args|
        Prerequisites::CancelValidation.call(validation.reload)
        native_result
      end

      execute!(report)

      expect(validation.status).to eq("cancelled")
      expect(validation.result["checks"]["native_analyzer"]).to include("status" => "succeeded")
      expect(validation.result["checks"]["tool_sidecar"]).to include("status" => "skipped")
      expect(validation.result["checks"]["cleanup"]["status"]).to eq("succeeded")
    end

    it "never executes a validation that was cancelled before pickup" do
      validation.update!(status: "cancelled", completed_at: Time.current)

      expect(described_class.call(validation, capability_report: report, provisioner_class: provisioner_class)).to eq(validation)
      expect(run).not_to have_received(:provision_execution_environment)
      expect(AgentRun).not_to have_received(:create!)
    end
  end

  describe "sidecar not requested" do
    it "skips the sidecar check and stays succeeded on a passing native run" do
      validation.update!(include_tool_sidecar: false)

      execute!(report)

      expect(validation.status).to eq("succeeded")
      expect(validation.result["checks"]["tool_sidecar"]).to include("status" => "skipped")
      expect(validation.result["requested_checks"]).to eq(%w[native_analyzer])
    end
  end
end
