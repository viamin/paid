# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ClaimQueuedAgentRunActivity do
  let(:activity) { described_class.new }

  describe "#execute" do
    it "claims a queued run, marks it pending, and stores the workflow id" do
      agent_run = create(:agent_run, :queued)

      result = activity.execute(
        agent_run_id: agent_run.id,
        workflow_id: "draft-followup-#{agent_run.id}"
      )

      expect(result).to eq({ claimed: true, agent_run_id: agent_run.id })
      expect(agent_run.reload.status).to eq("pending")
      expect(agent_run.temporal_workflow_id).to eq("draft-followup-#{agent_run.id}")
    end

    it "returns claimed: false when the run is no longer queued" do
      agent_run = create(:agent_run, status: "pending")

      result = activity.execute(
        agent_run_id: agent_run.id,
        workflow_id: "draft-followup-#{agent_run.id}"
      )

      expect(result).to eq({ claimed: false })
      expect(agent_run.reload.temporal_workflow_id).to be_blank
    end
  end
end
