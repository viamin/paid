# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CheckRunCapacityActivity do
  let(:activity) { described_class.new }

  describe "#execute" do
    it "returns has_capacity: false without a project context (fail closed)" do
      result = activity.execute({})

      expect(result[:has_capacity]).to be false
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

      it "uses Docker-backed auto admission in auto mode" do
        project = create(:project)
        user = project.created_by
        user.settings.update!(run_concurrency_mode: "auto", max_concurrent_runs: nil)
        allow(Capacity::DockerSnapshot).to receive(:fetch).and_return(
          available: true,
          effective_agent_budget_bytes: 2 * 1024 * 1024 * 1024,
          snapshot_at: Time.current,
          confidence: "high",
          docker_memory_bytes: 8 * 1024 * 1024 * 1024
        )

        result = activity.execute({ project_id: project.id })

        expect(result[:has_capacity]).to be false
        expect(result[:reason]).to eq("insufficient_docker_capacity")
      end
    end
  end
end
