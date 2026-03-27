# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetrics::DashboardStats do
  describe ".call" do
    let(:project) { create(:project) }

    context "with no metrics" do
      it "returns zero counts in overview" do
        result = described_class.call(project: project)

        expect(result[:overview][:total_metrics]).to eq(0)
        expect(result[:overview][:average_score]).to be_nil
      end

      it "returns empty trends" do
        result = described_class.call(project: project)

        expect(result[:trends]).to be_empty
      end

      it "returns empty breakdown" do
        result = described_class.call(project: project)

        expect(result[:breakdown]).to be_empty
      end

      it "returns empty prompt comparison" do
        result = described_class.call(project: project)

        expect(result[:prompt_comparison]).to be_empty
      end

      it "returns zero human feedback" do
        result = described_class.call(project: project)

        expect(result[:human_feedback][:total]).to eq(0)
      end
    end

    context "with metrics" do
      let(:automated_run) { create(:agent_run, project: project) }
      let(:human_run) { create(:agent_run, :with_custom_prompt, project: project) }

      before do
        create(:quality_metric, agent_run: automated_run, composite_score: 0.8)
        create(:quality_metric, :human, agent_run: human_run, composite_score: 0.6)
      end

      it "computes overview statistics" do
        result = described_class.call(project: project)

        expect(result[:overview][:total_metrics]).to eq(2)
        expect(result[:overview][:average_score]).to eq(0.7)
        expect(result[:overview][:min_score]).to eq(0.6)
        expect(result[:overview][:max_score]).to eq(0.8)
        expect(result[:overview][:automated_count]).to eq(1)
        expect(result[:overview][:human_count]).to eq(1)
      end

      it "returns trend data points" do
        result = described_class.call(project: project)

        expect(result[:trends].size).to eq(2)
        expect(result[:trends].first).to include(:score, :date, :metric_type)
      end

      it "returns score breakdown for automated metrics" do
        result = described_class.call(project: project)

        expect(result[:breakdown]).to include("pr_created", "ci_passed")
      end
    end

    context "with prompt versions" do
      it "compares prompt effectiveness" do
        prompt = create(:prompt, :with_version)
        version = prompt.current_version
        run = create(:agent_run, project: project, prompt_version: version)
        create(:quality_metric, agent_run: run, prompt_version: version, composite_score: 0.9)

        result = described_class.call(project: project)

        expect(result[:prompt_comparison].size).to eq(1)
        expect(result[:prompt_comparison].first[:prompt_name]).to eq(prompt.name)
        expect(result[:prompt_comparison].first[:avg_score]).to eq(0.9)
      end
    end

    it "includes metrics reference in response" do
      result = described_class.call(project: project)

      expect(result[:metrics_reference]).to be_an(Array)
      expect(result[:metrics_reference].size).to be > 0

      pr_created = result[:metrics_reference].find { |m| m[:key] == "pr_created" }
      expect(pr_created[:name]).to eq("PR Created")
      expect(pr_created[:weights_by_goal]).to eq("create_pr" => 0.25)
      expect(pr_created[:goal_types]).to include("create_pr")

      issue_created = result[:metrics_reference].find { |m| m[:key] == "issue_created" }
      expect(issue_created[:goal_types]).to include("create_issue")

      review_posted = result[:metrics_reference].find { |m| m[:key] == "review_posted" }
      expect(review_posted[:goal_types]).to include("review")

      # reaction_score is collected for all goals but only weighted for create_issue and review
      reaction = result[:metrics_reference].find { |m| m[:key] == "reaction_score" }
      expect(reaction[:weights_by_goal]).to eq("create_issue" => 0.60, "review" => 0.60)
      expect(reaction[:goal_types]).to contain_exactly("create_pr", "create_issue", "review")
    end

    context "with human feedback" do
      it "calculates merge rate" do
        merged_run = create(:agent_run, project: project)
        unmerged_run = create(:agent_run, :with_custom_prompt, project: project)
        create(:quality_metric, :human, agent_run: merged_run,
          scores: { "pr_merged" => 1.0 }, composite_score: 1.0)
        create(:quality_metric, :human, agent_run: unmerged_run,
          scores: { "pr_merged" => 0.0 }, composite_score: 0.0,
          feedback_source: "pr_review")

        result = described_class.call(project: project)

        expect(result[:human_feedback][:total]).to eq(2)
        expect(result[:human_feedback][:merge_rate]).to eq(50.0)
      end

      it "returns reaction and review counts and scores" do
        reaction_run = create(:agent_run, project: project)
        review_run = create(:agent_run, :with_custom_prompt, project: project)
        create(:quality_metric, :human, agent_run: reaction_run,
          scores: { "reaction_score" => 0.75 }, composite_score: 0.75)
        create(:quality_metric, :human, agent_run: review_run,
          scores: { "review_score" => 1.0 }, composite_score: 1.0,
          feedback_source: "pr_review")

        result = described_class.call(project: project)

        expect(result[:human_feedback][:reactions][:count]).to eq(1)
        expect(result[:human_feedback][:reactions][:average_score]).to eq(0.75)
        expect(result[:human_feedback][:reviews][:count]).to eq(1)
        expect(result[:human_feedback][:reviews][:average_score]).to eq(1.0)
      end

      it "returns zero reactions and reviews when none exist" do
        run = create(:agent_run, project: project)
        create(:quality_metric, :human, agent_run: run,
          scores: { "pr_merged" => 1.0 }, composite_score: 1.0)

        result = described_class.call(project: project)

        expect(result[:human_feedback][:reactions][:count]).to eq(0)
        expect(result[:human_feedback][:reactions][:average_score]).to be_nil
        expect(result[:human_feedback][:reviews][:count]).to eq(0)
        expect(result[:human_feedback][:reviews][:average_score]).to be_nil
      end
    end
  end
end
