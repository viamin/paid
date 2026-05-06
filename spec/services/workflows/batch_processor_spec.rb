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
      runs.each do |run|
        run.reload
        expect(run.status).to eq("completed")
        expect(run.completed_at).to be_present
        expect(run.duration_seconds).to be_present
      end
    end

    it "does not re-query loaded runs when transitioning a batch" do
      runs = create_list(:agent_run, 2, project: project, status: "running", started_at: 5.minutes.ago)
      scope = AgentRun.where(id: runs.map(&:id))

      expect(AgentRun).not_to receive(:where).with(hash_including(id: anything))

      described_class.call(scope: scope, operation: :complete)
    end

    it "batch-fails runs" do
      runs = create_list(:agent_run, 2, project: project, status: "running", started_at: 5.minutes.ago)
      scope = AgentRun.where(id: runs.map(&:id))

      result = described_class.call(scope: scope, operation: :fail)

      expect(result[:processed]).to eq(2)
      runs.each do |run|
        run.reload
        expect(run.status).to eq("failed")
        expect(run.completed_at).to be_present
        expect(run.duration_seconds).to be_present
      end
    end

    it "batch-requeues runs and clears stale execution state" do
      runs = create_list(:agent_run, 2, **stale_paused_attributes)
      scope = AgentRun.where(id: runs.map(&:id))

      result = described_class.call(scope: scope, operation: :requeue)

      expect(result[:processed]).to eq(2)
      runs.each { |run| expect_requeued_run(run) }
    end

    it "does not re-query loaded runs when requeuing a batch" do
      runs = create_list(:agent_run, 2, **stale_paused_attributes)
      scope = AgentRun.where(id: runs.map(&:id))

      expect(AgentRun).not_to receive(:where).with(hash_including(id: anything))

      described_class.call(scope: scope, operation: :requeue)
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

  def stale_paused_attributes
    {
      project:,
      status: "paused",
      started_at: 5.minutes.ago,
      completed_at: Time.current,
      duration_seconds: 120,
      error_message: "stale",
      stale_requeue_count: 1,
      stale_skip_count: 2,
      temporal_workflow_id: "workflow-123",
      temporal_run_id: "run-123",
      service_environment: { "REDIS_URL" => "redis://example.test:6379/0" },
      container_id: "container-123",
      service_container_ids: [ 1, 2 ],
      paused_at: 1.minute.ago,
      guardrail_violation_type: "loop_detected",
      guardrail_context: { "violation_type" => "loop_detected" }
    }
  end

  def expect_requeued_run(run)
    run.reload

    expect(run.attributes.slice(
      "status",
      "started_at",
      "completed_at",
      "duration_seconds",
      "paused_at",
      "guardrail_violation_type",
      "guardrail_context",
      "error_message",
      "stale_requeue_count",
      "stale_skip_count",
      "temporal_workflow_id",
      "temporal_run_id",
      "service_environment",
      "container_id",
      "service_container_ids"
    )).to eq(
      "status" => "queued",
      "started_at" => nil,
      "completed_at" => nil,
      "duration_seconds" => nil,
      "paused_at" => nil,
      "guardrail_violation_type" => nil,
      "guardrail_context" => nil,
      "error_message" => nil,
      "stale_requeue_count" => 2,
      "stale_skip_count" => 0,
      "temporal_workflow_id" => nil,
      "temporal_run_id" => nil,
      "service_environment" => nil,
      "container_id" => nil,
      "service_container_ids" => []
    )
  end
end
