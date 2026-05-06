# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::BatchProcessor do
  let(:project) { create(:project) }

  describe ".call" do
    it "batch-updates timed out runs" do
      runs = create_list(:agent_run, 3, project: project, status: "running", started_at: 5.minutes.ago)
      scope = AgentRun.where(id: runs.map(&:id))

      result = described_class.call(scope: scope, operation: :timeout)

      expect(result[:processed]).to eq(3)
      expect(result[:errors]).to be_empty
      runs.each do |run|
        run.reload
        expect(run.status).to eq("timeout")
        expect(run.error_message).to eq(described_class::TIMEOUT_ERROR_MESSAGE)
        expect(run.completed_at).to be_present
        expect(run.duration_seconds).to be_present
      end
    end

    it "batch-completes runs" do
      runs = create_list(:agent_run, 2, project: project, status: "running", started_at: 5.minutes.ago)
      scope = AgentRun.where(id: runs.map(&:id))

      result = described_class.call(scope: scope, operation: :complete)

      expect(result[:processed]).to eq(2)
      runs.each { |r| expect(r.reload.status).to eq("completed") }
    end

    it "batch-fails runs" do
      runs = create_list(:agent_run, 2, project: project, status: "running", started_at: 5.minutes.ago)
      scope = AgentRun.where(id: runs.map(&:id))

      result = described_class.call(scope: scope, operation: :fail)

      expect(result[:processed]).to eq(2)
      runs.each { |r| expect(r.reload.status).to eq("failed") }
    end

    it "batch-requeues runs and increments stale_requeue_count" do
      runs = create_list(:agent_run, 2, project: project, status: "running", started_at: 5.minutes.ago, stale_requeue_count: 1)
      scope = AgentRun.where(id: runs.map(&:id))

      result = described_class.call(scope: scope, operation: :requeue)

      expect(result[:processed]).to eq(2)
      runs.each do |run|
        run.reload
        expect(run.status).to eq("queued")
        expect(run.stale_requeue_count).to eq(2)
      end
    end

    it "rejects unknown operations" do
      expect {
        described_class.call(scope: AgentRun.none, operation: :unknown)
      }.to raise_error(ArgumentError, /Unknown operation/)
    end

    it "respects batch_size parameter" do
      runs = create_list(:agent_run, 5, project: project, status: "running", started_at: 5.minutes.ago)
      scope = AgentRun.where(id: runs.map(&:id))

      result = described_class.call(scope: scope, operation: :timeout, batch_size: 2)

      expect(result[:processed]).to eq(5)
    end
  end
end
