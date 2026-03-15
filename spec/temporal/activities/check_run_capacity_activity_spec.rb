# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CheckRunCapacityActivity do
  let(:activity) { described_class.new }

  describe "#execute" do
    it "returns has_capacity: true without a project context" do
      create(:agent_run, :running)

      result = activity.execute({})

      expect(result[:has_capacity]).to be true
      expect(result[:user_active_count]).to be_nil
      expect(result[:max_concurrent_runs]).to be_nil
    end

    it "does not count queued runs as active" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 1)
      create(:agent_run, :queued, project: project)

      result = activity.execute({ project_id: project.id })

      expect(result[:has_capacity]).to be true
      expect(result[:user_active_count]).to eq(0)
    end

    it "does not count finished runs as active" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 1)
      create(:agent_run, :completed, project: project)
      create(:agent_run, :failed, project: project)

      result = activity.execute({ project_id: project.id })

      expect(result[:has_capacity]).to be true
      expect(result[:user_active_count]).to eq(0)
    end

    context "with project_id providing user context" do
      it "returns false when user reaches their max" do
        project = create(:project)
        user = project.created_by
        user.settings.update!(max_concurrent_runs: 1)
        create(:agent_run, :running, project: project)

        result = activity.execute({ project_id: project.id })

        expect(result[:has_capacity]).to be false
        expect(result[:max_concurrent_runs]).to eq(1)
      end

      it "returns true when user is below their max" do
        project = create(:project)
        user = project.created_by
        user.settings.update!(max_concurrent_runs: 5)
        # Runs from other users don't affect this user
        create(:agent_run, :running)
        create(:agent_run, :running)

        result = activity.execute({ project_id: project.id })

        expect(result[:has_capacity]).to be true
      end
    end
  end
end
