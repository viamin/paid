# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CheckProjectRunCapacityActivity do
  let(:activity) { described_class.new }

  describe "#execute" do
    it "returns has_capacity: false when project is not found" do
      result = activity.execute({ project_id: -1 })

      expect(result[:has_capacity]).to be false
      expect(result[:available_slots]).to eq(0)
      expect(result[:error]).to eq("project_not_found")
    end

    it "returns has_capacity: false when project has no owner" do
      project = create(:project)
      allow(Project).to receive(:find_by).with(id: project.id).and_return(project)
      allow(project).to receive(:effective_owner).and_return(nil)

      result = activity.execute({ project_id: project.id })

      expect(result[:has_capacity]).to be false
      expect(result[:available_slots]).to eq(0)
      expect(result[:error]).to eq("owner_not_found")
    end

    it "returns available slots based on project-level limit" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_parallel_agents_per_project: 3, max_concurrent_runs: 10)

      create(:agent_run, :running, project: project)

      result = activity.execute({ project_id: project.id })

      expect(result[:has_capacity]).to be true
      expect(result[:available_slots]).to eq(2)
      expect(result[:project_active_count]).to eq(1)
      expect(result[:max_parallel_per_project]).to eq(3)
    end

    it "returns has_capacity: false when project is at max parallel limit" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_parallel_agents_per_project: 2, max_concurrent_runs: 10)

      create(:agent_run, :running, project: project)
      create(:agent_run, project: project) # pending (default status)

      result = activity.execute({ project_id: project.id })

      expect(result[:has_capacity]).to be false
      expect(result[:available_slots]).to eq(0)
    end

    it "respects user-level concurrent run limit" do
      project = create(:project)
      other_project = create(:project, created_by: project.created_by, account: project.account)
      user = project.created_by
      user.settings.update!(max_parallel_agents_per_project: 5, max_concurrent_runs: 2)

      create(:agent_run, :running, project: other_project)

      result = activity.execute({ project_id: project.id })

      expect(result[:has_capacity]).to be true
      # project has 5 slots, but user only has 1 remaining
      expect(result[:available_slots]).to eq(1)
    end

    it "does not count finished runs" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_parallel_agents_per_project: 2, max_concurrent_runs: 10)

      create(:agent_run, :completed, project: project)
      create(:agent_run, :failed, project: project)

      result = activity.execute({ project_id: project.id })

      expect(result[:has_capacity]).to be true
      expect(result[:available_slots]).to eq(2)
    end

    it "includes pr_aggregation_enabled from project setting" do
      project = create(:project, pr_aggregation_enabled: true)

      result = activity.execute({ project_id: project.id })

      expect(result[:pr_aggregation_enabled]).to be true
    end

    it "does not count queued runs as active" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_parallel_agents_per_project: 1, max_concurrent_runs: 10)

      create(:agent_run, :queued, project: project)

      result = activity.execute({ project_id: project.id })

      expect(result[:has_capacity]).to be true
      expect(result[:available_slots]).to eq(1)
    end
  end
end
