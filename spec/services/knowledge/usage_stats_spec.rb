# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::UsageStats do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  describe "#usage_by_artifact_type" do
    subject(:result) { described_class.new(project: project).usage_by_artifact_type }

    context "with usage data" do
      before do
        run = create(:agent_run, project: project)
        create(:knowledge_usage_stat, agent_run: run, project: project, artifact_type: "route", artifact_count: 5)
        create(:knowledge_usage_stat, agent_run: run, project: project, artifact_type: "route", artifact_count: 3, context_type: "search")
        create(:knowledge_usage_stat, agent_run: run, project: project, artifact_type: "dependency", artifact_count: 2)
      end

      it "returns counts grouped by artifact type" do
        expect(result["route"]).to eq(8)
        expect(result["dependency"]).to eq(2)
      end
    end

    context "with goal filter" do
      before do
        run_pr = create(:agent_run, project: project, goal: "create_pr")
        run_review = create(:agent_run, project: project, goal: "review", source_pull_request_number: 99, custom_prompt: "review", issue: nil)
        create(:knowledge_usage_stat, agent_run: run_pr, project: project, artifact_type: "route", artifact_count: 5)
        create(:knowledge_usage_stat, agent_run: run_review, project: project, artifact_type: "route", artifact_count: 3)
      end

      it "filters by goal" do
        result = described_class.new(project: project).usage_by_artifact_type(goal: "create_pr")
        expect(result["route"]).to eq(5)
      end
    end

    context "with no data" do
      it "returns empty hash" do
        expect(result).to be_empty
      end
    end

    context "with date filtering" do
      before do
        run = create(:agent_run, project: project)
        create(:knowledge_usage_stat, agent_run: run, project: project, artifact_type: "route", artifact_count: 10, created_at: 60.days.ago)
        create(:knowledge_usage_stat, agent_run: run, project: project, artifact_type: "dependency", artifact_count: 5, created_at: 5.days.ago)
      end

      it "only includes data since the specified time" do
        result = described_class.new(project: project, since: 30.days.ago).usage_by_artifact_type
        expect(result).not_to have_key("route")
        expect(result["dependency"]).to eq(5)
      end
    end
  end

  describe "#usage_by_goal" do
    subject(:result) { described_class.new(project: project).usage_by_goal }

    before do
      run_pr = create(:agent_run, project: project, goal: "create_pr")
      run_review = create(:agent_run, project: project, goal: "review", source_pull_request_number: 99, custom_prompt: "review", issue: nil)
      create(:knowledge_usage_stat, agent_run: run_pr, project: project, artifact_type: "route", artifact_count: 10)
      create(:knowledge_usage_stat, agent_run: run_review, project: project, artifact_type: "route", artifact_count: 7)
    end

    it "returns counts grouped by goal" do
      expect(result["create_pr"]).to eq(10)
      expect(result["review"]).to eq(7)
    end
  end

  describe "#effectiveness_by_artifact_type" do
    subject(:result) { described_class.new(project: project).effectiveness_by_artifact_type }

    before do
      completed_run = create(:agent_run, :completed, project: project)
      failed_run = create(:agent_run, :failed, project: project, issue: nil, custom_prompt: "fix")
      create(:knowledge_usage_stat, agent_run: completed_run, project: project, artifact_type: "route", artifact_count: 5)
      create(:knowledge_usage_stat, agent_run: failed_run, project: project, artifact_type: "route", artifact_count: 3)
      create(:knowledge_usage_stat, agent_run: completed_run, project: project, artifact_type: "schema", artifact_count: 2, context_type: "search")
    end

    it "returns success rate per artifact type" do
      expect(result["route"][:total_runs]).to eq(2)
      expect(result["route"][:successful_runs]).to eq(1)
      expect(result["route"][:success_rate]).to eq(50.0)
    end

    it "returns 100% for types only used by successful runs" do
      expect(result["schema"][:total_runs]).to eq(1)
      expect(result["schema"][:successful_runs]).to eq(1)
      expect(result["schema"][:success_rate]).to eq(100.0)
    end
  end

  describe "#top_artifact_types" do
    subject(:result) { described_class.new(project: project).top_artifact_types(limit: 2) }

    before do
      run = create(:agent_run, project: project)
      create(:knowledge_usage_stat, agent_run: run, project: project, artifact_type: "route", artifact_count: 10)
      create(:knowledge_usage_stat, agent_run: run, project: project, artifact_type: "dependency", artifact_count: 5, context_type: "search")
      create(:knowledge_usage_stat, agent_run: run, project: project, artifact_type: "schema", artifact_count: 1, context_type: "search")
    end

    it "returns top N artifact types sorted descending" do
      expect(result).to eq([ [ "route", 10 ], [ "dependency", 5 ] ])
    end
  end

  describe "#least_used_artifact_types" do
    subject(:result) { described_class.new(project: project).least_used_artifact_types(limit: 2) }

    before do
      run = create(:agent_run, project: project)
      create(:knowledge_usage_stat, agent_run: run, project: project, artifact_type: "route", artifact_count: 10)
      create(:knowledge_usage_stat, agent_run: run, project: project, artifact_type: "dependency", artifact_count: 5, context_type: "search")
      create(:knowledge_usage_stat, agent_run: run, project: project, artifact_type: "schema", artifact_count: 1, context_type: "search")
    end

    it "returns bottom N artifact types sorted ascending" do
      expect(result).to eq([ [ "schema", 1 ], [ "dependency", 5 ] ])
    end
  end

  describe "#usage_by_context_type" do
    subject(:result) { described_class.new(project: project).usage_by_context_type }

    before do
      run = create(:agent_run, project: project)
      create(:knowledge_usage_stat, agent_run: run, project: project, artifact_type: "route", artifact_count: 10, context_type: "bundle")
      create(:knowledge_usage_stat, agent_run: run, project: project, artifact_type: "route", artifact_count: 3, context_type: "search")
    end

    it "returns counts grouped by context type" do
      expect(result["bundle"]).to eq(10)
      expect(result["search"]).to eq(3)
    end
  end
end
