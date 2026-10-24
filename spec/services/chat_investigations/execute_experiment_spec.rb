# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatInvestigations::ExecuteExperiment do
  describe "result formatting" do
    it "reports success with the retained output" do
      execution = described_class::Execution.new(
        exit_code: 0, stdout: "3 examples, 0 failures\n", stderr: "", session_id: "sess-1",
        stdout_truncated: false, stderr_truncated: false
      )

      expect(execution).to be_success
      expect(execution.result_text).to eq("Experiment completed (exit code 0).\n\nOutput:\n3 examples, 0 failures")
    end

    it "includes stderr when the runtime emitted it" do
      execution = described_class::Execution.new(
        exit_code: 0, stdout: "ok\n", stderr: "deprecation warning\n", session_id: nil,
        stdout_truncated: false, stderr_truncated: false
      )

      expect(execution.result_text).to include("Stderr:").and include("deprecation warning")
    end

    it "reports failure with the exit code and retained partial output" do
      execution = described_class::Execution.new(
        exit_code: 2, stdout: "half the suite ran\n", stderr: "Error: boom\n", session_id: nil,
        stdout_truncated: false, stderr_truncated: false
      )

      expect(execution).not_to be_success
      expect(execution.result_text).to include("Experiment failed (exit code 2)")
        .and include("half the suite ran").and include("Error: boom")
    end

    it "appends an explicit notice when output was truncated" do
      execution = described_class::Execution.new(
        exit_code: 0, stdout: "x" * 100, stderr: "", session_id: nil,
        stdout_truncated: true, stderr_truncated: false
      )

      expect(execution.result_text).to include("stdout truncated")
    end

    it "reports a runtime failure with the runtime error and partial output" do
      execution = described_class::Execution.new(
        exit_code: nil, stdout: "half the suite ran\n", stderr: "", session_id: nil,
        stdout_truncated: false, stderr_truncated: false, runtime_error: "Docker exec error: daemon died"
      )

      expect(execution).not_to be_success
      expect(execution.result_text)
        .to eq("Experiment failed (runtime error: Docker exec error: daemon died).\n\nOutput:\nhalf the suite ran")
    end
  end

  describe "execution" do
    it "executes the investigation prompt through the session runtime and records evidence" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "experiment", prompt: "Reproduce the failure")
      investigation.chat_session.update!(container_capability: "ready", container_ready_at: Time.current,
        container_id: "chat-container-abc123")
      backend = stub_agent_boundaries(stdout: "reproduced\nsession_id: aabbcc-42\n", stderr: "", exit_code: 0)

      execution = described_class.call(investigation:)

      expect(execution).to be_success
      expect(backend).to have_received(:exec_in_container).with(
        anything,
        [ "claude", "--print", "investigation" ],
        hash_including(wait: described_class::EXECUTION_TIMEOUT.to_i)
      )
      expect(investigation.reload.metadata["experiment"]).to include(
        "exit_code" => 0,
        "agent_session_id" => "aabbcc-42",
        "stdout_truncated" => false,
        "executed_at" => be_a(String)
      )
    end

    it "preserves evidence for a failed exit" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "experiment", prompt: "Reproduce the failure")
      investigation.chat_session.update!(container_capability: "ready", container_ready_at: Time.current,
        container_id: "chat-container-abc123")
      stub_agent_boundaries(stdout: "partial\n", stderr: "Error: nope\n", exit_code: 1)

      execution = described_class.call(investigation:)

      expect(execution).not_to be_success
      expect(execution.result_text).to include("Error: nope")
      expect(investigation.reload.metadata["experiment"]).to include("exit_code" => 1)
    end

    it "truncates oversized streams and flags the truncation" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "experiment", prompt: "Reproduce the failure")
      investigation.chat_session.update!(container_capability: "ready", container_ready_at: Time.current,
        container_id: "chat-container-abc123")
      stub_agent_boundaries(stdout: "y" * 150.kilobytes, stderr: "", exit_code: 0)

      execution = described_class.call(investigation:)

      expect(execution.stdout.bytesize).to be <= described_class::MAX_OUTPUT_BYTES
      expect(execution.stdout_truncated).to be(true)
      expect(investigation.reload.metadata["experiment"]).to include("stdout_truncated" => true)
    end

    it "retains bounded partial output and truncation evidence when the runtime fails mid-stream" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "experiment", prompt: "Reproduce the failure")
      investigation.chat_session.update!(container_capability: "ready", container_ready_at: Time.current,
        container_id: "chat-container-abc123")
      stub_agent_boundaries(stdout: "z" * 150.kilobytes, stderr: "", exit_code: 0,
        mid_stream_error: Docker::Error::DockerError.new("daemon died"))

      execution = described_class.call(investigation:)

      expect(execution).not_to be_success
      expect(execution.result_text).to include("runtime error").and include("daemon died")
      expect(execution.stdout.bytesize).to be <= described_class::MAX_OUTPUT_BYTES
      expect(execution.stdout_truncated).to be(true)
      evidence = investigation.reload.metadata["experiment"]
      expect(evidence).to include(
        "stdout_truncated" => true,
        "runtime_error" => a_string_including("daemon died")
      )
      expect(evidence).not_to have_key("exit_code")
    end
  end

  private

  def stub_agent_boundaries(stdout:, stderr:, exit_code:, mid_stream_error: nil)
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
      block&.call(:stdout, stdout)
      block&.call(:stderr, stderr) if stderr.present?
      raise mid_stream_error if mid_stream_error
      [ stdout.lines, stderr.present? ? stderr.lines : [], exit_code ]
    end
    allow(Containers).to receive(:backend).and_return(backend)
    backend
  end
end
