# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::DeadlineExecutor do
  let(:delegate) { instance_double(AgentHarness::CommandExecutor) }
  let(:executor) { described_class.new(delegate) }
  let(:result) { AgentHarness::CommandExecutor::Result.new(stdout: "ok", stderr: "", exit_code: 0, duration: 1) }

  # @spec LLM-ROUTING-006
  it "terminates the command before the outer container watchdog expires" do
    allow(delegate).to receive(:execute).and_return(result)

    expect(executor.execute([ "runner", "a prompt; with $shell syntax" ], timeout: 30, env: { "KEY" => "value" })).to eq(result)

    expect(delegate).to have_received(:execute).with(
      [ "timeout", "--signal=TERM", "--kill-after=5s", "30s", "runner", "a prompt; with $shell syntax" ],
      timeout: 40, env: { "KEY" => "value" })
  end

  # @spec LLM-ROUTING-006
  it "raises a typed timeout so the same environment can be retried" do
    allow(delegate).to receive(:execute).and_return(
      AgentHarness::CommandExecutor::Result.new(stdout: "", stderr: "", exit_code: 124, duration: 30))

    expect { executor.execute([ "runner", "prompt" ], timeout: 30) }.to raise_error(AgentHarness::TimeoutError)
  end

  # @spec LLM-ROUTING-006
  it "keeps string commands inside a shell under the process deadline" do
    allow(delegate).to receive(:execute).and_return(result)

    executor.execute("runner 'prompt'", timeout: 30)

    expect(delegate).to have_received(:execute).with(
      [ "timeout", "--signal=TERM", "--kill-after=5s", "30s", "sh", "-c", "runner 'prompt'" ], timeout: 40)
  end
end
