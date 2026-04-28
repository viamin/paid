# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::HarnessExecutor do
  let(:agent_run) { instance_double(AgentRun) }
  let(:executor) { described_class.new(agent_run) }

  describe "#execute" do
    it "delegates to execute_in_container and returns a CommandExecutor::Result" do
      container_result = Containers::Provision::Result.success(
        stdout: "OK", stderr: "", exit_code: 0
      )
      allow(agent_run).to receive(:execute_in_container).and_return(container_result)

      result = executor.execute(%w[echo hello], timeout: 30, env: { "FOO" => "bar" })

      expect(result).to be_a(AgentHarness::CommandExecutor::Result)
      expect(result.stdout).to eq("OK")
      expect(result.stderr).to eq("")
      expect(result.exit_code).to eq(0)
      expect(result).to be_success
    end

    it "translates nil env values to env -u wrapping" do
      container_result = Containers::Provision::Result.success(
        stdout: "", stderr: "", exit_code: 0
      )
      allow(agent_run).to receive(:execute_in_container).and_return(container_result)

      executor.execute(
        %w[codex exec test],
        env: { "KEEP" => "value", "UNSET_ME" => nil, "ALSO_UNSET" => nil }
      )

      expect(agent_run).to have_received(:execute_in_container).with(
        %w[env -u UNSET_ME -u ALSO_UNSET codex exec test],
        timeout: nil,
        stream: false,
        env: { "KEEP" => "value" },
        preparation: nil
      )
    end

    it "maps failed container results to non-zero exit codes" do
      container_result = Containers::Provision::Result.failure(
        error: "auth failed", stdout: "", stderr: "auth failed", exit_code: 1
      )
      allow(agent_run).to receive(:execute_in_container).and_return(container_result)

      result = executor.execute(%w[test])

      expect(result.exit_code).to eq(1)
      expect(result).to be_failed
    end

    it "forwards preparation to the container" do
      container_result = Containers::Provision::Result.success(
        stdout: "", stderr: "", exit_code: 0
      )
      preparation = instance_double(AgentHarness::ExecutionPreparation)
      allow(agent_run).to receive(:execute_in_container).and_return(container_result)

      executor.execute(%w[opencode run test], preparation: preparation)

      expect(agent_run).to have_received(:execute_in_container).with(
        %w[opencode run test],
        timeout: nil,
        stream: false,
        env: {},
        preparation: preparation
      )
    end
  end

  describe "#which" do
    it "returns a truthy path for any binary" do
      expect(executor.which("claude")).to be_truthy
    end
  end
end
