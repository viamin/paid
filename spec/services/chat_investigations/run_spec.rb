# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatInvestigations::Run do
  include_context "without qdrant vector search"

  describe "experiment investigations" do
    it "executes the prompt in the ready workspace and retains the output" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "experiment", prompt: "Run the focused tests", reserved_cost_cents: 10)
      investigation.created_by.add_role(:project_member, investigation.project)
      investigation.chat_session.update!(container_capability: "ready", container_ready_at: Time.current,
        container_id: "chat-container-abc123")
      stub_agent_execution(stdout: "3 examples, 0 failures\n")
      allow(Containers::ProvisionForChat).to receive(:call)

      described_class.call(investigation:)

      expect(Runners::HarnessExecutionPlan).to have_received(:for_runner_key)
        .with(hash_including(prompt: "Run the focused tests"))
      expect(investigation.reload).to have_attributes(
        status: "completed",
        reserved_cost_cents: 0,
        started_at: be_present,
        finished_at: be_present
      )
      expect(investigation.result).to include("exit code 0").and include("3 examples, 0 failures")
      expect(investigation.metadata["experiment"]).to include("exit_code" => 0)
    end

    it "executes after provisioning readies the session" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "experiment", reserved_cost_cents: 10)
      investigation.created_by.add_role(:project_member, investigation.project)
      allow(Containers::ProvisionForChat).to receive(:call) do |chat_session:, **|
        chat_session.update!(container_capability: "ready", container_ready_at: Time.current,
          container_id: "chat-container-abc123")
      end
      backend = stub_agent_execution(stdout: "experiment ran\n")

      described_class.call(investigation:)

      expect(Containers::ProvisionForChat).to have_received(:call)
      expect(backend).to have_received(:exec_in_container)
      expect(investigation.reload.result).to include("experiment ran")
    end

    it "reuses an already ready workspace without provisioning a duplicate container" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "experiment", reserved_cost_cents: 10)
      investigation.created_by.add_role(:project_member, investigation.project)
      investigation.chat_session.update!(container_capability: "ready", container_ready_at: Time.current,
        container_id: "chat-container-abc123")
      allow(Containers::ProvisionForChat).to receive(:call)
      stub_agent_execution(stdout: "reused workspace output\n")

      described_class.call(investigation:)

      expect(Containers::ProvisionForChat).not_to have_received(:call)
      expect(investigation.reload).to have_attributes(status: "completed", reserved_cost_cents: 0)
      expect(investigation.result).to include("reused workspace output")
    end

    it "does not race an in-flight workspace provision" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "experiment", reserved_cost_cents: 10)
      investigation.created_by.add_role(:project_member, investigation.project)
      investigation.chat_session.update!(container_capability: "provisioning")
      allow(Containers::ProvisionForChat).to receive(:call)
      backend = stub_agent_execution

      described_class.call(investigation:)

      expect(Containers::ProvisionForChat).not_to have_received(:call)
      expect(backend).not_to have_received(:exec_in_container)
      expect(investigation.reload).to have_attributes(
        status: "failed",
        result: "Isolated workspace is unavailable",
        reserved_cost_cents: 0
      )
    end

    it "fails the investigation when the workspace never becomes ready" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "experiment", reserved_cost_cents: 10)
      investigation.created_by.add_role(:project_member, investigation.project)
      allow(Containers::ProvisionForChat).to receive(:call)
      backend = stub_agent_execution

      described_class.call(investigation:)

      expect(backend).not_to have_received(:exec_in_container)
      expect(investigation.reload).to have_attributes(
        status: "failed",
        result: "Isolated workspace is unavailable",
        reserved_cost_cents: 0
      )
    end

    it "marks a non-zero experiment exit as failed while retaining the output" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "experiment", reserved_cost_cents: 10)
      investigation.created_by.add_role(:project_member, investigation.project)
      investigation.chat_session.update!(container_capability: "ready", container_ready_at: Time.current,
        container_id: "chat-container-abc123")
      stub_agent_execution(stdout: "partial progress\n", stderr: "Error: fixture missing\n", exit_code: 1)

      described_class.call(investigation:)

      expect(investigation.reload).to have_attributes(status: "failed", reserved_cost_cents: 0)
      expect(investigation.result).to include("exit code 1").and include("partial progress").and include("fixture missing")
      expect(investigation.metadata["experiment"]).to include("exit_code" => 1)
    end

    it "settles a mid-stream runtime failure as failed while retaining the partial output and evidence" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "experiment", reserved_cost_cents: 10)
      investigation.created_by.add_role(:project_member, investigation.project)
      investigation.chat_session.update!(container_capability: "ready", container_ready_at: Time.current,
        container_id: "chat-container-abc123")
      stub_agent_execution(stdout: "partial progress\n",
        mid_stream_error: Docker::Error::DockerError.new("daemon died"))

      described_class.call(investigation:)

      expect(investigation.reload).to have_attributes(status: "failed", reserved_cost_cents: 0)
      expect(investigation.result).to include("runtime error").and include("daemon died").and include("partial progress")
      expect(investigation.metadata["experiment"]).to include("runtime_error" => a_string_including("daemon died"))
    end

    it "exposes executing progress and broadcasts it before the experiment runs" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "experiment", reserved_cost_cents: 10)
      investigation.created_by.add_role(:project_member, investigation.project)
      investigation.chat_session.update!(container_capability: "ready", container_ready_at: Time.current,
        container_id: "chat-container-abc123")
      observed_progress = nil
      stub_agent_execution(stdout: "done\n") { observed_progress = investigation.reload.metadata["progress"] }

      expect {
        described_class.call(investigation:)
      }.to have_broadcasted_to("chat_session:#{investigation.chat_session_id}")
        .with(hash_including(type: "investigation_updated", status: "running", progress: "executing"))

      expect(observed_progress).to eq("executing")
    end

    it "does not begin execution after the investigation is cancelled mid-run" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "experiment", reserved_cost_cents: 10)
      investigation.created_by.add_role(:project_member, investigation.project)
      allow(Containers::ProvisionForChat).to receive(:call) do |chat_session:, **|
        ChatInvestigations::Cancel.call(investigation: investigation.reload, actor: investigation.created_by)
        chat_session.update!(container_capability: "ready", container_ready_at: Time.current,
          container_id: "chat-container-abc123")
      end
      backend = stub_agent_execution

      described_class.call(investigation:)

      expect(backend).not_to have_received(:exec_in_container)
      expect(investigation.reload).to have_attributes(status: "cancelled", reserved_cost_cents: 0, result: nil)
    end

    it "preserves a cancellation that lands during execution without consuming the budget" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "experiment", reserved_cost_cents: 10)
      investigation.created_by.add_role(:project_member, investigation.project)
      investigation.chat_session.update!(container_capability: "ready", container_ready_at: Time.current,
        container_id: "chat-container-abc123")
      budget = create(:cost_budget, :hard_stop, :daily, project: investigation.project, limit_cents: 100)
      stub_agent_execution(stdout: "late output\n") do
        ChatInvestigations::Cancel.call(investigation: investigation.reload, actor: investigation.created_by)
      end

      described_class.call(investigation:)

      expect(investigation.reload).to have_attributes(
        status: "cancelled",
        reserved_cost_cents: 0,
        result: nil
      )
      expect(investigation.metadata).to include("cancelled_by_id" => investigation.created_by_id)
      expect(budget.reload.current_usage_cents).to eq(0)
    end

    it "truncates oversized experiment output and records the truncation" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "experiment", reserved_cost_cents: 10)
      investigation.created_by.add_role(:project_member, investigation.project)
      investigation.chat_session.update!(container_capability: "ready", container_ready_at: Time.current,
        container_id: "chat-container-abc123")
      stub_agent_execution(stdout: ("x" * 150.kilobytes) + "\n")

      described_class.call(investigation:)

      expect(investigation.reload.result.bytesize).to be < 120.kilobytes
      expect(investigation.result).to include("truncated")
      expect(investigation.metadata["experiment"]).to include("stdout_truncated" => true)
    end
  end

  describe "research investigations" do
    it "labels the result with the executed knowledge-search scope" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "research", reserved_cost_cents: 10)
      investigation.created_by.add_role(:project_member, investigation.project)
      project_version = create(:project_version, project: investigation.project)
      collector_run = create(:collector_run, project_version:, collector_type: "routes")
      artifact = create(:knowledge_artifact, project: investigation.project, collector_run:,
        identifier: investigation.prompt, content: "Repository evidence")
      create(:knowledge_chunk, project: investigation.project, knowledge_artifact: artifact,
        content: "Repository evidence")

      described_class.call(investigation:)

      expect(investigation.reload).to have_attributes(status: "completed", reserved_cost_cents: 0)
      expect(investigation.result).to start_with("Knowledge-base search results for this question:")
      expect(investigation.result).to include("Repository evidence")
    end

    it "reports honestly when no knowledge evidence matches" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "research", prompt: "Unmatched question", reserved_cost_cents: 10)
      investigation.created_by.add_role(:project_member, investigation.project)

      described_class.call(investigation:)

      expect(investigation.reload).to have_attributes(status: "completed", reserved_cost_cents: 0)
      expect(investigation.result).to include("No project knowledge-base evidence matched this investigation")
    end
  end

  describe "interrupted runs" do
    it "settles a re-entered running investigation as failed" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "research", status: "running",
        reserved_cost_cents: 80, started_at: 1.minute.ago)

      described_class.call(investigation:)

      expect(investigation.reload).to have_attributes(
        status: "failed",
        result: "Execution was interrupted before completion.",
        reserved_cost_cents: 0,
        finished_at: be_present
      )
    end

    it "releases the stranded reservation without charging the budget" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "research", status: "running",
        reserved_cost_cents: 80, started_at: 1.minute.ago)
      budget = create(:cost_budget, :hard_stop, :daily, project: investigation.project, limit_cents: 100)

      described_class.call(investigation:)

      expect(budget.reload.current_usage_cents).to eq(0)
    end
  end

  private

  # Stubs the external container/agent-harness boundaries the executor rides:
  # Docker (Containers.backend) and the harness execution plan. The optional
  # block runs when the container exec starts, acting as the mid-execution hook.
  def stub_agent_execution(stdout: "Experiment output\n", stderr: "", exit_code: 0, mid_stream_error: nil, on_exec: nil, &exec_hook)
    harness_result = Runners::HarnessExecutionPlan::Result.new(
      command: [ "claude", "--print", "investigation" ], env: {}, preparation: nil
    )
    allow(Runners::HarnessExecutionPlan).to receive_messages(for_runner_key: harness_result, call: harness_result)

    container = instance_double(
      Docker::Container,
      id: "chat-container-abc123",
      refresh!: true,
      info: { "State" => { "Running" => true } }
    )
    backend = instance_double(Containers::Backends::Base)
    allow(backend).to receive(:get_container).with("chat-container-abc123").and_return(container)
    allow(backend).to receive(:exec_in_container) do |_container, _command, **_options, &block|
      exec_hook&.call
      on_exec&.call
      block&.call(:stdout, stdout)
      block&.call(:stderr, stderr) if stderr.present?
      raise mid_stream_error if mid_stream_error
      [ stdout.lines, stderr.present? ? stderr.lines : [], exit_code ]
    end
    allow(Containers).to receive(:backend).and_return(backend)
    backend
  end
end
