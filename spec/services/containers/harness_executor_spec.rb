# frozen_string_literal: true

require "rails_helper"

# @spec AGENT-HARNESS-002
RSpec.describe Containers::HarnessExecutor do
  let(:agent_run) { instance_double(AgentRun) }
  let(:executor) { described_class.new(agent_run) }

  describe "#execute" do
    it "delegates to execute_in_execution_environment and returns a CommandExecutor::Result" do
      container_result = Containers::Provision::Result.success(
        stdout: "OK", stderr: "", exit_code: 0
      )
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(100.0, 100.25)
      allow(agent_run).to receive(:execute_in_execution_environment).and_return(container_result)

      result = executor.execute(%w[echo hello], timeout: 30, env: { "FOO" => "bar" })

      expect(result).to be_a(AgentHarness::CommandExecutor::Result)
      expect(result.stdout).to eq("OK")
      expect(result.stderr).to eq("")
      expect(result.exit_code).to eq(0)
      expect(result.duration).to eq(0.25)
      expect(result).to be_success
    end

    it "translates nil env values to env -u wrapping" do
      container_result = Containers::Provision::Result.success(
        stdout: "", stderr: "", exit_code: 0
      )
      allow(agent_run).to receive(:execute_in_execution_environment).and_return(container_result)

      executor.execute(
        %w[codex exec test],
        env: { "KEEP" => "value", "UNSET_ME" => nil, "ALSO_UNSET" => nil }
      )

      expect(agent_run).to have_received(:execute_in_execution_environment).with(
        %w[env -u UNSET_ME -u ALSO_UNSET codex exec test],
        timeout: nil,
        stream: false,
        env: { "KEEP" => "value" },
        preparation: nil
      )
    end

    it "shell-escapes env var names in the string-command unset path" do
      container_result = Containers::Provision::Result.success(
        stdout: "", stderr: "", exit_code: 0
      )
      allow(agent_run).to receive(:execute_in_execution_environment).and_return(container_result)

      executor.execute(
        "kilo run test",
        env: { "SAFE_VAR" => nil }
      )

      expect(agent_run).to have_received(:execute_in_execution_environment).with(
        [ "sh", "-c", "env -u SAFE_VAR kilo run test" ],
        timeout: nil,
        stream: false,
        env: {},
        preparation: nil
      )
    end

    it "maps failed container results to non-zero exit codes" do
      container_result = Containers::Provision::Result.failure(
        error: "auth failed", stdout: "", stderr: "auth failed", exit_code: 1
      )
      allow(agent_run).to receive(:execute_in_execution_environment).and_return(container_result)

      result = executor.execute(%w[test])

      expect(result.exit_code).to eq(1)
      expect(result).to be_failed
    end

    it "injects --auto and --print-logs for kilocode commands" do
      container_result = Containers::Provision::Result.success(
        stdout: "", stderr: "", exit_code: 0
      )
      allow(agent_run).to receive(:execute_in_execution_environment).and_return(container_result)

      executor.execute(%w[kilo run --format json hello])

      expect(agent_run).to have_received(:execute_in_execution_environment).with(
        %w[kilo run --auto --print-logs --format json hello],
        timeout: nil,
        stream: false,
        env: {},
        preparation: nil
      )
    end

    it "does not double-inject --auto when already present" do
      container_result = Containers::Provision::Result.success(
        stdout: "", stderr: "", exit_code: 0
      )
      allow(agent_run).to receive(:execute_in_execution_environment).and_return(container_result)

      executor.execute(%w[kilo run --auto --format json hello])

      expect(agent_run).to have_received(:execute_in_execution_environment).with(
        %w[kilo run --auto --format json hello],
        timeout: nil,
        stream: false,
        env: {},
        preparation: nil
      )
    end

    it "does not inject flags for non-kilo commands" do
      container_result = Containers::Provision::Result.success(
        stdout: "", stderr: "", exit_code: 0
      )
      allow(agent_run).to receive(:execute_in_execution_environment).and_return(container_result)

      executor.execute(%w[codex exec test])

      expect(agent_run).to have_received(:execute_in_execution_environment).with(
        %w[codex exec test],
        timeout: nil,
        stream: false,
        env: {},
        preparation: nil
      )
    end

    it "injects flags even when kilo command is wrapped by env -u" do
      container_result = Containers::Provision::Result.success(
        stdout: "", stderr: "", exit_code: 0
      )
      allow(agent_run).to receive(:execute_in_execution_environment).and_return(container_result)

      executor.execute(%w[kilo run --format json hello], env: { "STAY" => "val", "REMOVE" => nil })

      expect(agent_run).to have_received(:execute_in_execution_environment).with(
        %w[env -u REMOVE kilo run --auto --print-logs --format json hello],
        timeout: nil,
        stream: false,
        env: { "STAY" => "val" },
        preparation: nil
      )
    end

    it "forwards preparation to the container" do
      container_result = Containers::Provision::Result.success(
        stdout: "", stderr: "", exit_code: 0
      )
      preparation = instance_double(AgentHarness::ExecutionPreparation)
      allow(agent_run).to receive(:execute_in_execution_environment).and_return(container_result)

      executor.execute(%w[opencode run test], preparation: preparation)

      expect(agent_run).to have_received(:execute_in_execution_environment).with(
        %w[opencode run test],
        timeout: nil,
        stream: false,
        env: {},
        preparation: preparation
      )
    end
  end

  describe "#which" do
    it "returns the resolved path for an installed binary" do
      container_result = Containers::Provision::Result.success(
        stdout: "/usr/local/bin/claude\n", stderr: "", exit_code: 0
      )
      allow(agent_run).to receive(:execute_in_execution_environment).and_return(container_result)

      expect(executor.which("claude")).to eq("/usr/local/bin/claude")
      expect(agent_run).to have_received(:execute_in_execution_environment).with(
        [ "sh", "-c", "command -v -- claude" ],
        stream: false,
        env: {},
        preparation: nil
      )
    end

    it "shell-escapes the binary name for the command probe" do
      container_result = Containers::Provision::Result.success(
        stdout: "", stderr: "", exit_code: 0
      )
      allow(agent_run).to receive(:execute_in_execution_environment).and_return(container_result)
      binary = "claude; rm -rf /"

      executor.which(binary)

      expect(agent_run).to have_received(:execute_in_execution_environment).with(
        [ "sh", "-c", "command -v -- #{Shellwords.escape(binary)}" ],
        stream: false,
        env: {},
        preparation: nil
      )
    end

    it "returns nil when the binary is not installed" do
      container_result = Containers::Provision::Result.failure(
        error: "not found", stdout: "", stderr: "", exit_code: 1
      )
      allow(agent_run).to receive(:execute_in_execution_environment).and_return(container_result)

      expect(executor.which("claude")).to be_nil
    end
  end

  describe "#available?" do
    it "returns true when which resolves a binary" do
      allow(executor).to receive(:which).with("claude").and_return("/usr/local/bin/claude")

      expect(executor.available?("claude")).to be(true)
    end

    it "returns false when which does not resolve a binary" do
      allow(executor).to receive(:which).with("claude").and_return(nil)

      expect(executor.available?("claude")).to be(false)
    end
  end
end
