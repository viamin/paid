# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CheckRunCapacityActivity do
  let(:activity) { described_class.new }

  describe "#execute" do
    before do
      allow(Rails.application.config.x).to receive(:max_concurrent_runs).and_return(2)
    end

    it "returns has_capacity: true when below limit" do
      create(:agent_run, :running)

      result = activity.execute({})

      expect(result[:has_capacity]).to be true
      expect(result[:active_count]).to eq(1)
      expect(result[:max_concurrent_runs]).to eq(2)
    end

    it "returns has_capacity: false when at limit" do
      create(:agent_run, :running)
      create(:agent_run) # pending counts as active

      result = activity.execute({})

      expect(result[:has_capacity]).to be false
      expect(result[:active_count]).to eq(2)
    end

    it "does not count queued runs as active" do
      create(:agent_run, :running)
      create(:agent_run, :queued)

      result = activity.execute({})

      expect(result[:has_capacity]).to be true
      expect(result[:active_count]).to eq(1)
    end

    it "does not count finished runs as active" do
      create(:agent_run, :completed)
      create(:agent_run, :failed)

      result = activity.execute({})

      expect(result[:has_capacity]).to be true
      expect(result[:active_count]).to eq(0)
    end

    context "with project_id providing user context" do
      it "uses min of system config and user setting" do
        allow(Rails.application.config.x).to receive(:max_concurrent_runs).and_return(5)
        project = create(:project)
        user = project.created_by
        user.settings.update!(max_concurrent_runs: 1)
        create(:agent_run, :running, project: project)

        result = activity.execute({ project_id: project.id })

        expect(result[:has_capacity]).to be false
        expect(result[:max_concurrent_runs]).to eq(1)
      end

      it "returns false when global cap is reached even if user has capacity" do
        allow(Rails.application.config.x).to receive(:max_concurrent_runs).and_return(2)
        project = create(:project)
        user = project.created_by
        user.settings.update!(max_concurrent_runs: 5)
        # Two runs from other users fill the global cap
        create(:agent_run, :running)
        create(:agent_run, :running)

        result = activity.execute({ project_id: project.id })

        expect(result[:has_capacity]).to be false
      end
    end
  end
end
