# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::TrackParallelProgressActivity do
  let(:activity) { described_class.new }

  describe "#execute" do
    it "returns zero counts for empty agent_run_ids" do
      result = activity.execute({ parent_workflow_id: "test-wf", agent_run_ids: [] })

      expect(result[:total]).to eq(0)
      expect(result[:completed]).to eq(0)
      expect(result[:failed]).to eq(0)
      expect(result[:active]).to eq(0)
      expect(result[:all_finished]).to be false
    end

    it "tracks progress of multiple agent runs" do
      project = create(:project)
      completed_run = create(:agent_run, :completed, project: project)
      running_run = create(:agent_run, :running, project: project)
      failed_run = create(:agent_run, :failed, project: project)

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
      completed_run = create(:agent_run, :completed, project: project)
      failed_run = create(:agent_run, :failed, project: project)

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
      cancelled_run = create(:agent_run, :cancelled, project: project)

      result = activity.execute({
        parent_workflow_id: "test-wf",
        agent_run_ids: [ cancelled_run.id ]
      })

      expect(result[:total]).to eq(1)
      expect(result[:cancelled]).to eq(1)
      expect(result[:all_finished]).to be true
    end
  end
end
