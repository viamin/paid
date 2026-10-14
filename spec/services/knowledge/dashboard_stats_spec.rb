# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::DashboardStats do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  around do |example|
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.clear
    example.run
  ensure
    Rails.cache = original_cache
  end

  describe ".call" do
    subject(:stats) { described_class.call(account: account) }

    context "with no knowledge data" do
      before { project } # ensure project exists

      # @spec KNOWLEDGE-DASHBOARD-001
      it "reports missing credentials rather than ready when no runner state exists" do
        expect(stats).to include(
          projects_indexed: 0,
          projects_total: 1,
          total_artifacts: 0,
          stale_artifacts: 0,
          stale_percent: 0,
          artifacts_by_type: [],
          last_collection_at: nil
        )
        expect(stats[:operational_status]).to eq("unavailable")
        expect(stats[:provider_health][:embedding_available]).to be false
        expect(stats[:provider_health][:chat_available]).to be false
        expect(stats[:provider_health][:embedding].first).to include(
          configuration_status: "missing_credential",
          operational_status: "healthy",
          available: false
        )
      end
    end

    context "with a project that has no effective owner" do
      let(:project) do
        create(:project,
          account: account,
          created_by: nil,
          github_token: create(:github_token, :without_creator, account: account))
      end

      before { project }

      # @spec KNOWLEDGE-DASHBOARD-002
      it "omits the project from runner health" do
        provider_health = stats[:provider_health]

        expect(provider_health).to include(
          embedding: [],
          chat: [],
          project_count: 0,
          owner_count: 0
        )
      end
    end

    context "with a changed credential" do
      let(:owner) { project.effective_owner }

      before { project }

      # @spec KNOWLEDGE-DASHBOARD-002
      it "invalidates cached readiness when an owner adds an API key" do
        expect(stats[:provider_health][:embedding].first[:configuration_status]).to eq("missing_credential")

        create(:provider_api_key, user: owner, api_service_type: "openai", api_key: "sk-openai")

        refreshed = described_class.call(account: account)
        expect(refreshed[:provider_health][:embedding].first[:configuration_status]).to eq("ready")
      end
    end

    context "with changed runner settings" do
      let(:owner) { project.effective_owner }

      before { project }

      # @spec KNOWLEDGE-DASHBOARD-002
      it "invalidates cached readiness when an owner changes the configured runner" do
        expect(stats[:provider_health][:embedding].first[:runner]).to eq("openai")

        owner.settings.update!(kb_embedding_runner: "openrouter")

        refreshed = described_class.call(account: account)
        expect(refreshed[:provider_health][:embedding].first[:runner]).to eq("openrouter")
      end
    end

    context "with a changed managed runner credential" do
      let(:owner) { project.effective_owner }

      before { project }

      # @spec KNOWLEDGE-DASHBOARD-002
      it "does not report chat ready when the account adds an unusable managed credential" do
        expect(stats[:provider_health][:chat].first[:configuration_status]).to eq("missing_credential")

        create(:runner_credential, account: account, created_by: owner, runner_key: owner.settings.kb_chat_runner)

        refreshed = described_class.call(account: account)
        expect(refreshed[:provider_health][:chat].first).to include(
          configuration_status: "missing_credential",
          credential_source: nil,
          available: false
        )
      end
    end

    context "with only an owner API key for decision drafting" do
      let(:owner) { project.effective_owner }

      before do
        project
        create(:provider_api_key, user: owner, api_service_type: "anthropic", api_key: "sk-anthropic")
      end

      # @spec KNOWLEDGE-DASHBOARD-001
      it "reports chat ready because drafting materializes the owner API key" do
        chat = stats[:provider_health][:chat].first

        expect(chat).to include(
          configuration_status: "ready",
          credential_source: "owner_api_key",
          credential_service: "anthropic",
          available: true
        )
      end
    end

    context "with Codex configured for decision drafting" do
      let(:owner) { project.effective_owner }

      before do
        project
        owner.settings.update!(kb_chat_runner: "codex", kb_chat_fallback_runners: [])
      end

      # @spec KNOWLEDGE-DASHBOARD-001
      it "reports the OpenAI credential materialized by the Codex execution path" do
        create(:provider_api_key, user: owner, api_service_type: "openai", api_key: "sk-openai")

        chat = stats[:provider_health][:chat].first

        expect(chat).to include(
          configuration_status: "ready",
          credential_source: "owner_api_key",
          credential_service: "openai",
          available: true
        )
      end

      # @spec KNOWLEDGE-DASHBOARD-001
      it "does not report an Anthropic key as usable by Codex" do
        create(:provider_api_key, user: owner, api_service_type: "anthropic", api_key: "sk-anthropic")

        chat = stats[:provider_health][:chat].first

        expect(chat).to include(
          configuration_status: "missing_credential",
          credential_source: nil,
          credential_service: nil,
          available: false
        )
      end
    end

    context "with changed project ownership" do
      let(:first_owner) { create(:user, account: account) }
      let(:second_owner) { create(:user, account: account) }
      let(:project) { create(:project, account: account, created_by: first_owner) }

      before do
        project
        create(:provider_api_key, user: first_owner, api_service_type: "openai", api_key: "sk-first")
      end

      # @spec KNOWLEDGE-DASHBOARD-002
      it "invalidates cached readiness when a project changes effective owner" do
        expect(stats[:provider_health][:embedding]).to include(
          hash_including(owner_id: first_owner.id, configuration_status: "ready")
        )

        project.update!(created_by: second_owner)

        refreshed = described_class.call(account: account)
        expect(refreshed[:provider_health][:embedding]).to include(
          hash_including(owner_id: second_owner.id, configuration_status: "missing_credential")
        )
      end
    end

    context "with an unsupported configured transport" do
      let(:owner) { project.effective_owner }

      before { owner.settings.update_columns(kb_embedding_runner: "claude") }

      # @spec KNOWLEDGE-DASHBOARD-001
      it "reports unsupported transport separately from missing credentials" do
        embedding = stats[:provider_health][:embedding].first

        expect(embedding[:configuration_status]).to eq("unsupported_transport")
        expect(embedding[:available]).to be(false)
      end
    end

    context "with configured credentials" do
      let(:owner) { project.effective_owner }

      before do
        create(:provider_api_key, user: owner, api_service_type: "openai", api_key: "sk-openai")
        create(:provider_api_key, user: owner, api_service_type: "anthropic", api_key: "sk-anthropic")
        create(:runner_credential, account: account, created_by: owner, runner_key: owner.settings.kb_chat_runner)
      end

      # @spec KNOWLEDGE-DASHBOARD-001
      it "reports safe credential metadata without claiming a live validation" do
        embedding = stats[:provider_health][:embedding].first
        chat = stats[:provider_health][:chat].first

        expect(embedding).to include(
          configuration_status: "ready",
          credential_source: "owner_api_key",
          credential_service: "openai",
          validated_with_provider: false
        )
        expect(chat).to include(
          configuration_status: "ready",
          credential_source: "owner_api_key",
          credential_service: "anthropic",
          validated_with_provider: false
        )
      end
    end

    context "with the platform OpenAI fallback" do
      let(:owner) { project.effective_owner }

      before do
        project
        allow(Rails.application.credentials).to receive(:dig).with(:llm, :openai_api_key).and_return(nil)
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return("platform-key")
      end

      # @spec KNOWLEDGE-DASHBOARD-001
      it "reports the fallback source without exposing its value" do
        embedding = stats[:provider_health][:embedding].first

        expect(embedding).to include(
          configuration_status: "ready",
          credential_source: "platform_fallback",
          credential_service: "openai"
        )
        expect(embedding.values).not_to include("platform-key")
      end
    end

    context "with the platform Anthropic fallback for decision drafting" do
      let(:owner) { project.effective_owner }

      before do
        project
        owner.settings.update!(kb_chat_runner: "claude", kb_chat_fallback_runners: [])
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return("platform-key")
      end

      # @spec KNOWLEDGE-DASHBOARD-001
      it "reports the credential source without exposing its value" do
        chat = stats[:provider_health][:chat].first

        expect(chat).to include(
          configuration_status: "ready",
          credential_source: "platform_fallback",
          credential_service: "anthropic"
        )
        expect(chat.values).not_to include("platform-key")
      end
    end

    context "with different project effective owners" do
      let(:first_owner) { create(:user, account: account) }
      let(:second_owner) { create(:user, account: account) }
      let(:first_project) { create(:project, account: account, created_by: first_owner) }
      let(:second_project) { create(:project, account: account, created_by: second_owner) }

      before do
        first_project
        second_project
        create(:provider_api_key, user: first_owner, api_service_type: "openai", api_key: "sk-first")
      end

      # @spec KNOWLEDGE-DASHBOARD-002
      it "aggregates readiness by each project's effective owner" do
        embedding = stats[:provider_health][:embedding]

        expect(stats[:provider_health][:scope]).to eq("project_effective_owners")
        expect(embedding).to include(hash_including(owner_id: first_owner.id, configuration_status: "ready"))
        expect(embedding).to include(hash_including(owner_id: second_owner.id, configuration_status: "missing_credential"))
      end

      # @spec KNOWLEDGE-DASHBOARD-002
      it "batch-loads readiness data for all effective owners" do
        additional_owners = create_list(:user, 3, account: account)
        additional_owners.each { |owner| create(:project, account: account, created_by: owner) }

        queries = capture_queries { stats }

        readiness_table_patterns.each do |pattern|
          expect(queries.grep(pattern).size).to be <= 2
        end
      end
    end

    context "with unavailable runner states" do
      let(:owner) { create(:user, account: account) }
      let(:project) do
        create(:project,
          account: account,
          created_by: owner,
          github_token: create(:github_token, account: account, created_by: owner))
      end

      before do
        project
        create(:runner_state, :rate_limited, user: owner, runner_name: owner.settings.kb_embedding_runner)
        create(:runner_state, :circuit_open, user: owner, runner_name: owner.settings.kb_chat_runner)
      end

      it "reports runner health and degraded operational status" do
        embedding = stats[:provider_health][:embedding].first
        chat = stats[:provider_health][:chat].first

        expect(embedding[:runner]).to eq(owner.settings.kb_embedding_runner)
        expect(embedding[:available]).to be false
        expect(embedding[:rate_limited]).to be true

        expect(chat[:runner]).to eq(owner.settings.kb_chat_runner)
        expect(chat[:available]).to be false
        expect(chat[:circuit_state]).to eq("open")

        expect(stats[:operational_status]).to eq("unavailable")
      end

      it "checks circuit recovery once per configured runner state" do
        dashboard = described_class.new(account: account)
        allow(dashboard).to receive(:runner_status).and_call_original

        dashboard.call

        expect(dashboard).to have_received(:runner_status).twice
      end

      it "does not report an expired rate limit as active" do
        expired_time = 2.minutes.ago
        owner.runner_states.find_by!(runner_name: owner.settings.kb_embedding_runner)
          .update!(rate_limited_until: expired_time)

        embedding = stats[:provider_health][:embedding].first

        expect(embedding[:rate_limited]).to be(false)
        expect(embedding[:rate_limited_until]).to be_within(1.second).of(expired_time)
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
          final_runner: "openai",
          created_at: 20.minutes.ago,
          updated_at: 10.minutes.ago)
        create(:knowledge_run, :failed,
          project: project,
          operation_type: "embedding",
          runner_attempts: [ { "runner" => "azure_openai" } ],
          created_at: 9.minutes.ago,
          updated_at: 5.minutes.ago)
        create(:knowledge_run, :completed, :decision_drafting,
          project: project,
          final_runner: "claude",
          created_at: 7.minutes.ago,
          updated_at: 4.minutes.ago)
      end

      it "summarizes success rate, latency, and runner distribution by operation" do
        embedding = stats[:pipeline_metrics]["embedding"]
        drafting = stats[:pipeline_metrics]["decision_drafting"]

        expect(embedding[:total_runs]).to eq(2)
        expect(embedding[:successful_runs]).to eq(1)
        expect(embedding[:failed_runs]).to eq(1)
        expect(embedding[:success_rate]).to eq(50.0)
        expect(embedding[:avg_duration_seconds]).to eq(420.0)
        expect(embedding[:runner_distribution]).to contain_exactly(
          hash_including(runner: "azure_openai", run_count: 1, success_rate: 0.0, avg_duration_seconds: 240.0),
          hash_including(runner: "openai", run_count: 1, success_rate: 100.0, avg_duration_seconds: 600.0)
        )

        expect(drafting[:total_runs]).to eq(1)
        expect(drafting[:success_rate]).to eq(100.0)
        expect(drafting[:runner_distribution]).to contain_exactly(
          hash_including(runner: "claude", run_count: 1, success_rate: 100.0)
        )
      end

      it "falls back to unknown when a run has no recorded runner" do
        create(:knowledge_run, :failed,
          project: project,
          operation_type: "embedding",
          final_runner: nil,
          runner_attempts: [],
          created_at: 6.minutes.ago,
          updated_at: 3.minutes.ago)

        distribution = stats[:pipeline_metrics]["embedding"][:runner_distribution]

        expect(distribution).to include(
          hash_including(runner: "unknown", run_count: 1, success_rate: 0.0)
        )
      end

      context "when unfinished runs exist in the lookback window" do
        before do
          create(:knowledge_run, :running,
            project: project,
            operation_type: "embedding",
            final_runner: "openai",
            created_at: 5.minutes.ago,
            updated_at: 1.minute.ago)
          create(:knowledge_run,
            project: project,
            operation_type: "decision_drafting",
            status: "pending",
            final_runner: "claude",
            created_at: 4.minutes.ago,
            updated_at: 2.minutes.ago)
        end

        it "excludes unfinished runs from pipeline totals and rates" do
          embedding = stats[:pipeline_metrics]["embedding"]
          drafting = stats[:pipeline_metrics]["decision_drafting"]

          expect(embedding[:total_runs]).to eq(2)
          expect(embedding[:finished_runs]).to eq(2)
          expect(embedding[:successful_runs]).to eq(1)
          expect(embedding[:failed_runs]).to eq(1)
          expect(embedding[:success_rate]).to eq(50.0)

          expect(drafting[:total_runs]).to eq(1)
          expect(drafting[:finished_runs]).to eq(1)
          expect(drafting[:successful_runs]).to eq(1)
          expect(drafting[:success_rate]).to eq(100.0)
        end

        it "excludes unfinished runs from runner distribution counts" do
          distribution = stats[:pipeline_metrics]["embedding"][:runner_distribution]

          expect(distribution).to contain_exactly(
            hash_including(runner: "azure_openai", run_count: 1, success_rate: 0.0),
            hash_including(runner: "openai", run_count: 1, success_rate: 100.0)
          )
        end
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

      it "reuses cached pipeline metrics until the cache entry expires" do
        first_dashboard = described_class.new(account: account)
        second_dashboard = described_class.new(account: account)

        allow(first_dashboard).to receive(:build_pipeline_metrics).and_call_original
        allow(second_dashboard).to receive(:build_pipeline_metrics).and_call_original

        expect(first_dashboard.call[:pipeline_metrics]["embedding"][:total_runs]).to eq(0)

        create(:knowledge_run, :completed,
          project: project,
          operation_type: "embedding",
          final_runner: "openai")

        expect(second_dashboard.call[:pipeline_metrics]["embedding"][:total_runs]).to eq(0)
        expect(first_dashboard).to have_received(:build_pipeline_metrics).once
        expect(second_dashboard).not_to have_received(:build_pipeline_metrics)
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

      # @spec KNOWLEDGE-CURATED-005
      it "buckets usage by curated/derived lane" do
        run = create(:agent_run, project: project, goal: "create_pr")
        create(:knowledge_usage_stat, agent_run: run, project: project, artifact_type: "decision_record", artifact_count: 4)

        expect(stats[:usage_by_lane]).to eq("curated" => 4, "derived" => 15)
      end
    end

    context "with no knowledge usage stats" do
      it "returns empty knowledge usage summary" do
        expect(stats[:knowledge_usage_summary]).to be_empty
      end

      it "returns empty usage by goal" do
        expect(stats[:usage_by_goal]).to be_empty
      end

      it "returns zero counts for usage by lane" do
        expect(stats[:usage_by_lane]).to eq("curated" => 0, "derived" => 0)
      end
    end

    context "with caching" do
      let(:version) { create(:project_version, project: project) }
      let(:run) { create(:collector_run, :completed, project_version: version) }

      it "returns fresh artifact counts on each call (no outer cache)" do
        first = described_class.call(account: account)
        create(:knowledge_artifact, collector_run: run, project: project, artifact_type: "route")

        refreshed = described_class.call(account: account)

        expect(first[:total_artifacts]).to eq(0)
        expect(refreshed[:total_artifacts]).to eq(1)
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

  def capture_queries
    queries = []
    callback = lambda do |_name, _started, _finished, _unique_id, payload|
      queries << payload[:sql] if payload[:name] != "SCHEMA" && !payload[:cached]
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  def readiness_table_patterns
    [ /FROM "user_settings"/, /FROM "runner_states"/, /FROM "provider_api_keys"/ ]
  end
end
