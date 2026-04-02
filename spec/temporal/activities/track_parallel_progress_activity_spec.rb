# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::TrackParallelProgressActivity do
  let(:activity) { described_class.new }

  describe "#execute" do
    it "returns zero counts for empty agent_run_ids" do
      result = activity.execute({ parent_workflow_id: "test-wf", agent_run_ids: [] })

      expect(result[:total]).to eq(0)
      expect(result[:missing]).to eq(0)
      expect(result[:completed]).to eq(0)
      expect(result[:failed]).to eq(0)
      expect(result[:active]).to eq(0)
      expect(result[:all_finished]).to be false
    end

    it "tracks progress of multiple agent runs" do
      project = create(:project)
      completed_run = create(:agent_run, :completed, project: project, parent_workflow_id: "test-wf")
      running_run = create(:agent_run, :running, project: project, parent_workflow_id: "test-wf")
      failed_run = create(:agent_run, :failed, project: project, parent_workflow_id: "test-wf")

      result = activity.execute({
        parent_workflow_id: "test-wf",
        agent_run_ids: [ completed_run.id, running_run.id, failed_run.id ]
      })

      expect(result[:total]).to eq(3)
      expect(result[:completed]).to eq(1)
      expect(result[:failed]).to eq(1)
      expect(result[:active]).to eq(1)
      expect(result[:all_finished]).to be false
    end

    it "reports all_finished when all runs are done" do
      project = create(:project)
      completed_run = create(:agent_run, :completed, project: project, parent_workflow_id: "test-wf")
      failed_run = create(:agent_run, :failed, project: project, parent_workflow_id: "test-wf")

      result = activity.execute({
        parent_workflow_id: "test-wf",
        agent_run_ids: [ completed_run.id, failed_run.id ]
      })

      expect(result[:total]).to eq(2)
      expect(result[:completed]).to eq(1)
      expect(result[:failed]).to eq(1)
      expect(result[:all_finished]).to be true
    end

    it "counts cancelled runs toward finished" do
      project = create(:project)
      cancelled_run = create(:agent_run, :cancelled, project: project, parent_workflow_id: "test-wf")

      result = activity.execute({
        parent_workflow_id: "test-wf",
        agent_run_ids: [ cancelled_run.id ]
      })

      expect(result[:total]).to eq(1)
      expect(result[:cancelled]).to eq(1)
      expect(result[:all_finished]).to be true
    end

    it "scopes runs by parent_workflow_id when provided" do
      project = create(:project)
      matching_run = create(:agent_run, :completed, project: project, parent_workflow_id: "parent-wf-1")
      other_run = create(:agent_run, :completed, project: project, parent_workflow_id: "parent-wf-2")

      result = activity.execute({
        parent_workflow_id: "parent-wf-1",
        agent_run_ids: [ matching_run.id, other_run.id ]
      })

      expect(result[:total]).to eq(1)
      expect(result[:completed]).to eq(1)
      expect(result[:missing]).to eq(1)
    end

    it "handles missing agent run IDs without blocking all_finished" do
      project = create(:project)
      completed_run = create(:agent_run, :completed, project: project, parent_workflow_id: "test-wf")
      missing_id = -999

      result = activity.execute({
        parent_workflow_id: "test-wf",
        agent_run_ids: [ completed_run.id, missing_id ]
      })

      expect(result[:total]).to eq(1)
      expect(result[:missing]).to eq(1)
      expect(result[:completed]).to eq(1)
      expect(result[:all_finished]).to be true
    end
  end
end
