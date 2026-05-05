# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::DashboardStats do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  describe ".call" do
    subject(:stats) { described_class.call(account: account) }

    context "with no knowledge data" do
      before { project } # ensure project exists

      it "returns zero counts" do
        expect(stats[:projects_indexed]).to eq(0)
        expect(stats[:projects_total]).to eq(1)
        expect(stats[:total_artifacts]).to eq(0)
        expect(stats[:stale_artifacts]).to eq(0)
        expect(stats[:stale_percent]).to eq(0)
        expect(stats[:artifacts_by_type]).to be_empty
        expect(stats[:last_collection_at]).to be_nil
        expect(stats[:operational_status]).to eq("healthy")
        expect(stats[:provider_health][:embedding_available]).to be true
        expect(stats[:provider_health][:chat_available]).to be true
      end
    end

    context "with unavailable provider states" do
      let(:owner) { create(:user, account: account) }
      let(:project) do
        create(:project,
          account: account,
          created_by: owner,
          github_token: create(:github_token, account: account, created_by: owner))
      end

      before do
        project
        create(:provider_state, :rate_limited, user: owner, provider_name: owner.settings.kb_embedding_provider)
        create(:provider_state, :circuit_open, user: owner, provider_name: owner.settings.kb_chat_provider)
      end

      it "reports provider health and degraded operational status" do
        embedding = stats[:provider_health][:embedding].first
        chat = stats[:provider_health][:chat].first

        expect(embedding[:provider]).to eq(owner.settings.kb_embedding_provider)
        expect(embedding[:available]).to be false
        expect(embedding[:rate_limited]).to be true

        expect(chat[:provider]).to eq(owner.settings.kb_chat_provider)
        expect(chat[:available]).to be false
        expect(chat[:circuit_state]).to eq("open")

        expect(stats[:operational_status]).to eq("unavailable")
      end
    end

    context "with knowledge artifacts" do
      let(:version) { create(:project_version, project: project) }
      let(:run) { create(:collector_run, :completed, project_version: version) }

      before do
        create_list(:knowledge_artifact, 3, collector_run: run, project: project, artifact_type: "route")
        create_list(:knowledge_artifact, 2, collector_run: run, project: project, artifact_type: "dependency")
        create(:knowledge_artifact, :stale, collector_run: run, project: project, artifact_type: "route")
      end

      it "returns correct artifact counts" do
        expect(stats[:projects_indexed]).to eq(1)
        expect(stats[:total_artifacts]).to eq(5)
        expect(stats[:stale_artifacts]).to eq(1)
      end

      it "calculates stale percentage" do
        expect(stats[:stale_percent]).to eq(17)
      end

      it "returns artifacts by type sorted by count" do
        by_type = stats[:artifacts_by_type].to_h
        expect(by_type["route"]).to eq(3)
        expect(by_type["dependency"]).to eq(2)
      end

      it "returns last collection time" do
        expect(stats[:last_collection_at]).to be_within(1.second).of(run.completed_at)
      end
    end

    context "with knowledge runs for token usage" do
      before do
        create(:knowledge_run, project: project, operation_type: "embedding", total_tokens: 500, status: "completed")
        create(:knowledge_run, project: project, operation_type: "embedding", total_tokens: 300, status: "completed")
        create(:knowledge_run, project: project, operation_type: "decision_drafting", total_tokens: 1200, status: "completed")
      end

      it "returns token usage grouped by operation type" do
        summary = stats[:token_usage_summary]
        embedding = summary.find { |s| s[:operation_type] == "embedding" }
        drafting = summary.find { |s| s[:operation_type] == "decision_drafting" }

        expect(embedding[:total_tokens]).to eq(800)
        expect(embedding[:run_count]).to eq(2)
        expect(drafting[:total_tokens]).to eq(1200)
        expect(drafting[:run_count]).to eq(1)
      end

      it "excludes runs from other accounts" do
        other_account = create(:account)
        other_project = create(:project, account: other_account)
        create(:knowledge_run, project: other_project, operation_type: "embedding", total_tokens: 9999)

        summary = stats[:token_usage_summary]
        total = summary.sum { |s| s[:total_tokens] }
        expect(total).to eq(2000)
      end
    end

    context "with pipeline metrics" do
      before do
        create(:knowledge_run, :completed,
          project: project,
          operation_type: "embedding",
          final_provider: "openai",
          created_at: 20.minutes.ago,
          updated_at: 10.minutes.ago)
        create(:knowledge_run, :failed,
          project: project,
          operation_type: "embedding",
          provider_attempts: [ { "provider" => "azure_openai" } ],
          created_at: 9.minutes.ago,
          updated_at: 5.minutes.ago)
        create(:knowledge_run, :completed, :decision_drafting,
          project: project,
          final_provider: "claude",
          created_at: 7.minutes.ago,
          updated_at: 4.minutes.ago)
      end

      it "summarizes success rate, latency, and provider distribution by operation" do
        embedding = stats[:pipeline_metrics]["embedding"]
        drafting = stats[:pipeline_metrics]["decision_drafting"]

        expect(embedding[:total_runs]).to eq(2)
        expect(embedding[:successful_runs]).to eq(1)
        expect(embedding[:failed_runs]).to eq(1)
        expect(embedding[:success_rate]).to eq(50.0)
        expect(embedding[:avg_duration_seconds]).to eq(420.0)
        expect(embedding[:provider_distribution]).to contain_exactly(
          hash_including(provider: "azure_openai", run_count: 1, success_rate: 0.0, avg_duration_seconds: 240.0),
          hash_including(provider: "openai", run_count: 1, success_rate: 100.0, avg_duration_seconds: 600.0)
        )

        expect(drafting[:total_runs]).to eq(1)
        expect(drafting[:success_rate]).to eq(100.0)
        expect(drafting[:provider_distribution]).to contain_exactly(
          hash_including(provider: "claude", run_count: 1, success_rate: 100.0)
        )
      end
    end

    context "with no knowledge runs" do
      it "returns empty token usage summary" do
        expect(stats[:token_usage_summary]).to be_empty
      end

      it "returns empty pipeline metrics" do
        expect(stats[:pipeline_metrics]["embedding"]).to include(total_runs: 0, success_rate: 0.0)
        expect(stats[:pipeline_metrics]["decision_drafting"]).to include(total_runs: 0, success_rate: 0.0)
      end
    end

    context "with knowledge usage stats" do
      before do
        run = create(:agent_run, project: project, goal: "create_pr")
        create(:knowledge_usage_stat, agent_run: run, project: project, artifact_type: "route", artifact_count: 10)
        create(:knowledge_usage_stat, agent_run: run, project: project, artifact_type: "dependency", artifact_count: 5, context_type: "search")
      end

      it "returns knowledge usage summary grouped by artifact type" do
        summary = stats[:knowledge_usage_summary].to_h
        expect(summary["route"]).to eq(10)
        expect(summary["dependency"]).to eq(5)
      end

      it "returns usage by goal" do
        by_goal = stats[:usage_by_goal].to_h
        expect(by_goal["create_pr"]).to eq(15)
      end

      it "excludes usage from other accounts" do
        other_account = create(:account)
        other_project = create(:project, account: other_account)
        other_run = create(:agent_run, project: other_project)
        create(:knowledge_usage_stat, agent_run: other_run, project: other_project, artifact_type: "route", artifact_count: 999)

        summary = stats[:knowledge_usage_summary].to_h
        expect(summary["route"]).to eq(10)
      end
    end

    context "with no knowledge usage stats" do
      it "returns empty knowledge usage summary" do
        expect(stats[:knowledge_usage_summary]).to be_empty
      end

      it "returns empty usage by goal" do
        expect(stats[:usage_by_goal]).to be_empty
      end
    end

    context "with multiple projects" do
      let(:project2) { create(:project, account: account) }
      let(:other_account) { create(:account) }
      let(:other_project) { create(:project, account: other_account) }

      before do
        version1 = create(:project_version, project: project)
        run1 = create(:collector_run, :completed, project_version: version1)
        create(:knowledge_artifact, collector_run: run1, project: project)

        # project2 has no artifacts — should not be counted as indexed
        create(:project_version, project: project2)

        # other_account artifacts should not be counted
        other_version = create(:project_version, project: other_project)
        other_run = create(:collector_run, :completed, project_version: other_version)
        create(:knowledge_artifact, collector_run: other_run, project: other_project)
      end

      it "counts only projects in the account" do
        expect(stats[:projects_total]).to eq(2)
        expect(stats[:projects_indexed]).to eq(1)
        expect(stats[:total_artifacts]).to eq(1)
      end
    end
  end
end
