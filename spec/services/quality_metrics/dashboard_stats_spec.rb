# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetrics::DashboardStats do
  describe ".metrics_reference", :no_db do
    it "includes focus-specific weights for create_pr metrics" do
      result = described_class.metrics_reference

      ci_passed = result.find { |metric| metric[:key] == "ci_passed" }
      focus_resolved = result.find { |metric| metric[:key] == "focus_resolved" }

      expect(ci_passed[:weights_by_focus]).to eq(
        "ci_fix" => 0.45,
        "merge_conflict" => 0.135,
        "issue_implementation" => 0.135
      )
      expect(focus_resolved[:weights_by_focus]).to eq(
        "review_feedback" => 0.54,
        "merge_conflict" => 0.63,
        "conversation" => 0.54,
        "label_action" => 0.54,
        "issue_implementation" => 0.45
      )
    end
  end

  describe ".overview" do
    let(:project) { create(:project) }

    before do
      Rails.cache.clear
    end

    it "delegates to Rails.cache with the project-specific key and TTL" do
      expect(Rails.cache).to receive(:fetch)
        .with(described_class.overview_cache_key(project.id), hash_including(expires_in: described_class::OVERVIEW_CACHE_TTL))
        .and_call_original

      described_class.overview(project: project)
    end

    it "computes fresh data on cache miss" do
      automated_run = create(:agent_run, project: project)
      create(:quality_metric, agent_run: automated_run, composite_score: 0.8)

      result = described_class.overview(project: project)

      expect(result[:total_metrics]).to eq(1)
      expect(result[:average_score]).to eq(0.8)
    end

    it "invalidates the cached overview when quality metrics are created or updated" do
      automated_run = create(:agent_run, project: project)
      metric = create(:quality_metric, agent_run: automated_run, composite_score: 0.8)

      expect(described_class.overview(project: project)[:average_score]).to eq(0.8)

      create(:quality_metric, :human, agent_run: create(:agent_run, project: project), composite_score: 0.6)
      expect(described_class.overview(project: project)[:total_metrics]).to eq(2)

      metric.update!(composite_score: 0.4)

      refreshed = described_class.overview(project: project)

      expect(refreshed[:total_metrics]).to eq(2)
      expect(refreshed[:average_score]).to eq(0.5)
    end
  end

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
        expect(result[:overview][:automated_count]).to eq(1)
        expect(result[:overview][:human_count]).to eq(1)
      end

      it "returns score distribution with five bands" do
        result = described_class.call(project: project)
        dist = result[:overview][:score_distribution]

        expect(dist.size).to eq(5)
        expect(dist.map { |b| b[:label] }).to eq(%w[0–20 20–40 40–60 60–80 80–100])
        expect(dist.map { |b| b[:min] }).to eq([ 0.0, 0.2, 0.4, 0.6, 0.8 ])
        # 0.6 falls in 60–80 band, 0.8 falls in 80–100 band
        expect(dist[3][:count]).to eq(1)
        expect(dist[4][:count]).to eq(1)
        expect(dist[0][:count]).to eq(0)
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

    it "includes the metrics reference collection in the response" do
      result = described_class.call(project: project)

      expect(result[:metrics_reference]).to be_an(Array)
      expect(result[:metrics_reference].size).to be > 0
    end

    it "includes goal and focus weight metadata for core create_pr metrics" do
      result = described_class.call(project: project)

      pr_created = result[:metrics_reference].find { |m| m[:key] == "pr_created" }
      ci_passed = result[:metrics_reference].find { |m| m[:key] == "ci_passed" }
      focus_resolved = result[:metrics_reference].find { |m| m[:key] == "focus_resolved" }

      expect(pr_created[:name]).to eq("PR Created")
      expect(pr_created[:weights_by_goal]).to eq("create_pr" => 0.225)
      expect(pr_created[:weights_by_focus]).to eq({})
      expect(pr_created[:goal_types]).to include("create_pr")
      expect(ci_passed[:weights_by_focus]).to eq(
        "ci_fix" => 0.45,
        "merge_conflict" => 0.135,
        "issue_implementation" => 0.135
      )
      expect(focus_resolved[:weights_by_focus]).to eq(
        "review_feedback" => 0.54,
        "merge_conflict" => 0.63,
        "conversation" => 0.54,
        "label_action" => 0.54,
        "issue_implementation" => 0.45
      )
    end

    it "includes mutation kill-rate metadata for create_pr metrics" do
      result = described_class.call(project: project)
      mutation_kill_rate = result[:metrics_reference].find { |m| m[:key] == "mutation_kill_rate" }

      expect(mutation_kill_rate[:weights_by_goal]).to eq("create_pr" => 0.10)
      expect(mutation_kill_rate[:weights_by_focus]).to include(
        "ci_fix" => 0.10,
        "review_feedback" => 0.10,
        "merge_conflict" => 0.10
      )
    end

    it "includes goal metadata for non-create_pr metrics" do
      result = described_class.call(project: project)

      issue_created = result[:metrics_reference].find { |m| m[:key] == "issue_created" }
      review_posted = result[:metrics_reference].find { |m| m[:key] == "review_posted" }
      reaction = result[:metrics_reference].find { |m| m[:key] == "reaction_score" }

      expect(issue_created[:goal_types]).to include("create_issue")
      expect(review_posted[:goal_types]).to include("review")
      expect(reaction[:weights_by_goal]).to eq("create_issue" => 0.60, "review" => 0.60, "enhance_issue" => 0.35)
      expect(reaction[:weights_by_focus]).to eq({})
      expect(reaction[:goal_types]).to contain_exactly("create_pr", "create_issue", "review", "enhance_issue")
    end

    context "with tier breakdown" do
      let(:low_model) { create(:llm_model, tier: "low") }
      let(:high_model) { create(:llm_model, tier: "high") }

      it "computes avg quality score per tier" do
        low_run = create(:agent_run, project: project)
        create(:model_selection, agent_run: low_run, llm_model: low_model, tier: "low", selector_type: "rules")
        create(:quality_metric, agent_run: low_run, composite_score: 0.6)

        high_run = create(:agent_run, :with_custom_prompt, project: project)
        create(:model_selection, agent_run: high_run, llm_model: high_model, tier: "high", selector_type: "rules")
        create(:quality_metric, agent_run: high_run, composite_score: 0.9)

        tier_data = described_class.call(project: project)[:tier_breakdown]

        expect(tier_data.find { |t| t[:tier] == "low" }[:avg_score]).to eq(0.6)
        expect(tier_data.find { |t| t[:tier] == "high" }[:avg_score]).to eq(0.9)
      end

      it "tracks escalation rate by tier" do
        run = create(:agent_run, project: project)
        create(:model_selection, agent_run: run, llm_model: high_model, tier: "high", selector_type: "quality_escalation")

        tier_data = described_class.call(project: project)[:tier_breakdown]
        high_tier = tier_data.find { |t| t[:tier] == "high" }

        expect(high_tier[:run_count]).to eq(1)
        expect(high_tier[:escalation_count]).to eq(1)
        expect(high_tier[:escalation_rate]).to eq(100.0)
      end

      it "returns all three tiers with zeros when no model selections exist" do
        tier_data = described_class.call(project: project)[:tier_breakdown]

        expect(tier_data.size).to eq(3)
        expect(tier_data).to all(include(run_count: 0, avg_score: nil))
      end
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
