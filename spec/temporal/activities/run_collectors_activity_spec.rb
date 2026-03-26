# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RunCollectorsActivity, :no_db do
  let(:activity) { described_class.new }
  let(:project) { Struct.new(:id, :full_name).new(42, "owner/repo") }
  let(:commit_sha) { "a" * 40 }
  let(:collector_result) do
    {
      project_version: Object.new,
      results: [
        { collector_type: "symbol_index", status: "completed", artifacts_count: 5 }
      ]
    }
  end

  before do
    project_class = Class.new do
      def self.find(_id)
        raise "should be stubbed"
      end
    end
    stub_const("Project", project_class)
    allow(Project).to receive(:find).with(42).and_return(project)
  end

  describe "#execute" do
    context "when Docker is available" do
      before do
        allow(Knowledge::ContainerizedRunner).to receive_messages(available?: true, call: collector_result)
      end

      it "runs collectors in a container" do
        result = activity.execute(project_id: 42, commit_sha: commit_sha)

        expect(Knowledge::ContainerizedRunner).to have_received(:call).with(
          project: project,
          commit_sha: commit_sha,
          branch: "main",
          committed_at: nil
        )
        expect(result[:success]).to be true
        expect(result[:containerized]).to be true
      end
    end

    context "when Docker is unavailable" do
      before do
        allow(Knowledge::ContainerizedRunner).to receive(:available?).and_return(false)
        allow(Knowledge::CollectorRunner).to receive(:call).and_return(collector_result)
      end

      it "falls back to host execution" do
        result = activity.execute(project_id: 42, commit_sha: commit_sha)

        expect(Knowledge::CollectorRunner).to have_received(:call).with(
          project: project,
          commit_sha: commit_sha,
          branch: "main",
          committed_at: nil
        )
        expect(result[:success]).to be true
        expect(result[:containerized]).to be false
      end
    end

    context "when container execution fails" do
      before do
        allow(Knowledge::ContainerizedRunner).to receive(:available?).and_return(true)
        allow(Knowledge::ContainerizedRunner).to receive(:call).and_raise(
          Knowledge::ContainerizedRunner::ContainerError, "Docker error: out of memory"
        )
      end

      it "raises a Temporal application error" do
        expect {
          activity.execute(project_id: 42, commit_sha: commit_sha)
        }.to raise_error(Temporalio::Error::ApplicationError, /Containerized collector execution failed/)
      end
    end

    it "passes branch and committed_at parameters" do
      allow(Knowledge::ContainerizedRunner).to receive_messages(available?: true, call: collector_result)

      activity.execute(
        project_id: 42,
        commit_sha: commit_sha,
        branch: "develop",
        committed_at: "2026-01-01T00:00:00Z"
      )

      expect(Knowledge::ContainerizedRunner).to have_received(:call).with(
        project: project,
        commit_sha: commit_sha,
        branch: "develop",
        committed_at: "2026-01-01T00:00:00Z"
      )
    end
  end
end
