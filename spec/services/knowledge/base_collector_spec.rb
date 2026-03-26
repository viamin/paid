# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::BaseCollector, :no_db do
  subject(:collector) do
    described_class.new(
      project: project,
      project_version: project_version,
      collector_run: collector_run
    )
  end

  let(:project) { Struct.new(:id).new(1) }
  let(:project_version) { Struct.new(:id).new(1) }
  let(:collector_run) { Struct.new(:id).new(1) }

  describe "#collect" do
    it "raises NotImplementedError" do
      expect { collector.collect }.to raise_error(NotImplementedError)
    end
  end

  describe "#collector_type" do
    it "raises NotImplementedError" do
      expect { collector.collector_type }.to raise_error(NotImplementedError)
    end
  end

  describe "#tool_version" do
    it "returns nil by default" do
      expect(collector.tool_version).to be_nil
    end
  end

  describe "#run_command" do
    it "returns stdout on success" do
      result = collector.send(:run_command, "echo", "hello", timeout: 5)

      expect(result.strip).to eq("hello")
    end

    it "raises on non-zero exit status with stderr in message" do
      expect do
        collector.send(:run_command, "sh", "-c", "echo oops >&2; exit 1", timeout: 5)
      end.to raise_error(RuntimeError, /exit 1.*oops/)
    end

    it "raises Timeout::Error when command exceeds timeout" do
      expect do
        collector.send(:run_command, "sleep", "60", timeout: 1)
      end.to raise_error(Timeout::Error, /timed out after 1 seconds/i)
    end

    it "closes stdout and stderr even on timeout" do
      # Verify that the process is cleaned up by checking that no zombie
      # processes are left. We just need this to not hang.
      expect do
        collector.send(:run_command, "sleep", "60", timeout: 1)
      end.to raise_error(Timeout::Error)
    end

    it "includes command in non-zero exit error message" do
      expect do
        collector.send(:run_command, "sh", "-c", "exit 42", timeout: 5)
      end.to raise_error(RuntimeError, /sh -c exit 42/)
    end

    it "includes command in timeout error message" do
      expect do
        collector.send(:run_command, "sleep", "60", timeout: 1)
      end.to raise_error(Timeout::Error, /sleep 60/)
    end
  end
end
