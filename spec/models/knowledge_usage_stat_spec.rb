# frozen_string_literal: true

require "rails_helper"

RSpec.describe KnowledgeUsageStat do
  subject(:knowledge_usage_stat) { build(:knowledge_usage_stat) }

  describe "associations" do
    it { is_expected.to belong_to(:agent_run) }
    it { is_expected.to belong_to(:project).optional }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:artifact_type) }
    it { is_expected.to validate_length_of(:artifact_type).is_at_most(100) }
    it { is_expected.to validate_presence_of(:goal) }
    it { is_expected.to validate_length_of(:goal).is_at_most(50) }
    it { is_expected.to validate_presence_of(:context_type) }
    it { is_expected.to validate_length_of(:context_type).is_at_most(50) }
    it { is_expected.to validate_inclusion_of(:context_type).in_array(described_class::CONTEXT_TYPES) }

    it "rejects an invalid context_type" do
      stat = build(:knowledge_usage_stat, context_type: "unknown")
      expect(stat).not_to be_valid
      expect(stat.errors[:context_type]).to include(a_string_matching(/is not included/))
    end

    it { is_expected.to validate_presence_of(:artifact_count) }
    it { is_expected.to validate_numericality_of(:artifact_count).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_presence_of(:chunk_count) }
    it { is_expected.to validate_numericality_of(:chunk_count).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:token_count).is_greater_than_or_equal_to(0) }

    describe "project_matches_agent_run" do
      it "is invalid when project does not match agent run's project" do
        agent_run = create(:agent_run)
        other_project = create(:project)
        stat = build(:knowledge_usage_stat, agent_run: agent_run, project: other_project)
        expect(stat).not_to be_valid
        expect(stat.errors[:project]).to include("must match the agent run's project")
      end

      it "derives project from agent_run when project is omitted" do
        agent_run = create(:agent_run)
        stat = build(:knowledge_usage_stat, agent_run: agent_run, project: nil)
        stat.valid?
        expect(stat.project_id).to eq(agent_run.project_id)
      end
    end
  end

  describe "scopes" do
    let(:project) { create(:project) }
    let(:other_project) { create(:project) }
    let(:agent_run) { create(:agent_run, project: project) }
    let(:other_agent_run) { create(:agent_run, project: other_project) }

    describe ".for_project" do
      it "returns stats for the given project" do
        stat = create(:knowledge_usage_stat, agent_run: agent_run, project: project)
        create(:knowledge_usage_stat, agent_run: other_agent_run, project: other_project)

        expect(described_class.for_project(project)).to eq([ stat ])
      end
    end

    describe ".by_artifact_type" do
      it "filters by artifact type" do
        route_stat = create(:knowledge_usage_stat, agent_run: agent_run, project: project, artifact_type: "route")
        create(:knowledge_usage_stat, agent_run: create(:agent_run, project: project), project: project,
          artifact_type: "symbol", context_type: "search")

        expect(described_class.by_artifact_type("route")).to eq([ route_stat ])
      end
    end

    describe ".by_goal" do
      it "filters by goal" do
        analyze = create(:knowledge_usage_stat, agent_run: agent_run, project: project, goal: "analyze_issue")
        create(:knowledge_usage_stat, agent_run: create(:agent_run, project: project), project: project,
          goal: "create_pr")

        expect(described_class.by_goal("analyze_issue")).to eq([ analyze ])
      end
    end

    describe ".since" do
      it "returns stats created after the given time" do
        old_stat = create(:knowledge_usage_stat, agent_run: agent_run, project: project)
        old_stat.update_column(:created_at, 2.days.ago)

        recent_stat = create(:knowledge_usage_stat, agent_run: create(:agent_run, project: project),
          project: project, artifact_type: "symbol")

        expect(described_class.since(1.day.ago)).to eq([ recent_stat ])
      end
    end
  end

  describe "unique index" do
    it "prevents duplicate agent_run/artifact_type/context_type combinations" do
      stat = create(:knowledge_usage_stat)
      duplicate = build(:knowledge_usage_stat,
        agent_run: stat.agent_run,
        project: stat.project,
        artifact_type: stat.artifact_type,
        context_type: stat.context_type)

      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
