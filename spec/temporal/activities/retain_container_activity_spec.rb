# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RetainContainerActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }

  describe "#execute" do
    it "sets container_retained_until on the agent run" do
      agent_run = create(:agent_run, :running, project: project, container_id: "abc123")

      freeze_time do
        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:retained]).to be true
        expect(result[:retained_until]).to be_present
        agent_run.reload
        expect(agent_run.container_retained_until).to eq(4.hours.from_now)
      end
    end

    it "returns retained: false when agent run has no container" do
      agent_run = create(:agent_run, :running, project: project, container_id: nil)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:retained]).to be false
    end

    it "returns retained: false when agent run does not exist" do
      result = activity.execute(agent_run_id: -1)

      expect(result[:retained]).to be false
    end

    it "shortens retention TTL under disk pressure" do
      agent_run = create(:agent_run, :running, project: project, container_id: "abc123")
      allow(activity).to receive(:disk_pressure?).and_return(true)

      freeze_time do
        activity.execute(agent_run_id: agent_run.id)

        agent_run.reload
        expect(agent_run.container_retained_until).to eq(1.hour.from_now)
      end
    end
  end
end
