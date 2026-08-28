# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunPatterns::Detect do
  describe ".call" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }

    context "with no recent runs" do
      it "returns an empty array" do
        result = described_class.call(account: account)

        expect(result).to eq([])
      end
    end

    context "with only successful runs" do
      it "returns an empty array" do
        create_list(:agent_run, 5, :completed, project: project, goal: "enhance_issue")

        result = described_class.call(account: account)

        expect(result).to eq([])
      end
    end

    context "with a failure streak" do
      it "detects consecutive failures of the same goal type" do
        create_list(:agent_run, 3, :failed, project: project, goal: "enhance_issue",
          error_message: "No LLM provider produced an issue enhancement",
          completed_at: Time.current)

        result = described_class.call(account: account)

        streak_pattern = result.find { |p| p.type == :failure_streak }
        expect(streak_pattern).to be_present
        expect(streak_pattern.goal).to eq("enhance_issue")
        expect(streak_pattern.severity).to eq(:error)
        expect(streak_pattern.details[:streak_length]).to eq(3)
        expect(streak_pattern.details[:error_messages]).to include("No LLM provider produced an issue enhancement")
      end

      it "does not detect a streak below the threshold" do
        create_list(:agent_run, 2, :failed, project: project, goal: "enhance_issue",
          error_message: "Error", completed_at: Time.current)

        result = described_class.call(account: account)

        streak_pattern = result.find { |p| p.type == :failure_streak }
        expect(streak_pattern).to be_nil
      end

      it "breaks the streak when a successful run is interleaved" do
        create(:agent_run, :failed, project: project, goal: "enhance_issue",
          error_message: "Error", completed_at: 3.minutes.ago)
        create(:agent_run, :completed, project: project, goal: "enhance_issue",
          completed_at: 2.minutes.ago)
        create(:agent_run, :failed, project: project, goal: "enhance_issue",
          error_message: "Error", completed_at: 1.minute.ago)

        result = described_class.call(account: account)

        streak_pattern = result.find { |p| p.type == :failure_streak }
        expect(streak_pattern).to be_nil
      end

      it "ignores retried runs when evaluating the streak" do
        create(:agent_run, :failed, project: project, goal: "enhance_issue",
          error_message: "Error", completed_at: 4.minutes.ago)
        create(:agent_run, :retried, project: project, goal: "enhance_issue",
          completed_at: 3.minutes.ago)
        create(:agent_run, :failed, project: project, goal: "enhance_issue",
          error_message: "Error", completed_at: 2.minutes.ago)
        create(:agent_run, :failed, project: project, goal: "enhance_issue",
          error_message: "Error", completed_at: 1.minute.ago)

        result = described_class.call(account: account)

        streak_pattern = result.find { |p| p.type == :failure_streak }
        expect(streak_pattern).to be_present
        expect(streak_pattern.details[:streak_length]).to eq(3)
        expect(streak_pattern.details[:total_runs]).to eq(3)
      end
    end

    context "with a high failure rate" do
      it "detects when failure rate exceeds threshold with sufficient samples" do
        create(:agent_run, :completed, project: project, goal: "enhance_issue", completed_at: Time.current)
        create_list(:agent_run, 4, :failed, project: project, goal: "enhance_issue",
          error_message: "Error", completed_at: Time.current)

        result = described_class.call(account: account)

        rate_pattern = result.find { |p| p.type == :high_failure_rate }
        expect(rate_pattern).to be_present
        expect(rate_pattern.goal).to eq("enhance_issue")
        expect(rate_pattern.details[:failure_count]).to eq(4)
        expect(rate_pattern.details[:total_count]).to eq(5)
        expect(rate_pattern.details[:failure_rate]).to eq(0.8)
      end

      it "does not detect when sample size is below minimum" do
        create_list(:agent_run, 3, :failed, project: project, goal: "enhance_issue",
          error_message: "Error", completed_at: Time.current)

        result = described_class.call(account: account)

        rate_pattern = result.find { |p| p.type == :high_failure_rate }
        expect(rate_pattern).to be_nil
      end

      it "excludes retried runs from the sample size and denominator" do
        create_list(:agent_run, 4, :failed, project: project, goal: "enhance_issue",
          error_message: "Error", completed_at: Time.current)
        create(:agent_run, :completed, project: project, goal: "enhance_issue", completed_at: Time.current)
        create(:agent_run, :retried, project: project, goal: "enhance_issue", completed_at: Time.current)

        result = described_class.call(account: account)

        rate_pattern = result.find { |p| p.type == :high_failure_rate }
        expect(rate_pattern).to be_present
        expect(rate_pattern.details[:failure_count]).to eq(4)
        expect(rate_pattern.details[:total_count]).to eq(5)
        expect(rate_pattern.details[:failure_rate]).to eq(0.8)
      end
    end

    context "with error clusters" do
      let(:fixture_attempts) do
        JSON.parse(file_fixture("agent_run_patterns/model_metadata_not_found_runners_attempted.json").read)
      end

      let(:evidence_runner) do
        create(:llm_model, model_id: "gpt-4o", provider: "openai", tier: "high")
        create(
          :runner,
          user: project.created_by,
          runner_key: "kilocode",
          auth_type: "api_key",
          provider_api_key: create(:provider_api_key, user: project.created_by, api_service_type: "openai"),
          config: { "kilocode" => { "api_provider" => "openai", "model" => "gpt-4o" } },
          tier_model_ids: { "low" => "gpt-4o", "mid" => "gpt-4o", "high" => "gpt-4o" }
        )
      end

      it "detects multiple failures sharing the same error pattern" do
        create_list(:agent_run, 3, :failed, project: project, goal: "analyze_issue",
          error_message: "No LLM provider produced an issue analysis",
          completed_at: Time.current)

        result = described_class.call(account: account)

        cluster = result.find { |p| p.type == :error_cluster }
        expect(cluster).to be_present
        expect(cluster.goal).to eq("analyze_issue")
        expect(cluster.details[:occurrence_count]).to eq(3)
        expect(cluster.details[:sample_messages]).to include("No LLM provider produced an issue analysis")
      end

      # @spec ISSUE-ANALYSIS-013
      it "clusters analyze_issue provider-exhaustion failures on normalized failure categories instead of provider names" do
        create_provider_exhaustion_run("All issue-analysis providers exhausted: claude (auth_expired)")
        create_provider_exhaustion_run("All issue-analysis providers exhausted: codex (auth_expired)")
        # The third run attempted one more provider: attempt counts must not
        # split the cluster any more than provider names may.
        create_provider_exhaustion_run(
          "All issue-analysis providers exhausted: opencode (auth_expired), claude (auth_expired)",
          failure_log_count: 2
        )

        cluster = described_class.call(account: account).find { |pattern| pattern.type == :error_cluster }

        expect(cluster.goal).to eq("analyze_issue")
        expect(cluster.details[:occurrence_count]).to eq(3)
        expect(cluster.details[:error_pattern]).to eq("All issue-analysis providers exhausted: auth_expired")
        expect(cluster.details[:provider_failure_categories]).to eq("auth_expired" => 4)
        expect(cluster.details[:sample_messages]).to contain_exactly(
          "All issue-analysis providers exhausted: claude (auth_expired)",
          "All issue-analysis providers exhausted: codex (auth_expired)",
          "All issue-analysis providers exhausted: opencode (auth_expired), claude (auth_expired)"
        )
      end

      # @spec ISSUE-ANALYSIS-013
      # Structured provider-failure logs are persisted best-effort; without
      # them the detector still groups exhaustion failures on one stable key
      # instead of the variable free-text provider detail.
      it "clusters provider-exhaustion failures on the stable prefix when structured provider-failure logs are missing" do
        create_provider_exhaustion_run("All issue-analysis providers exhausted: claude (auth_expired)", failure_log_count: 0)
        create_provider_exhaustion_run("All issue-analysis providers exhausted: codex (installation)", failure_log_count: 0)
        create_provider_exhaustion_run("All issue-analysis providers exhausted", failure_log_count: 0)

        cluster = described_class.call(account: account).find { |pattern| pattern.type == :error_cluster }

        expect(cluster.details[:error_pattern]).to eq("All issue-analysis providers exhausted")
        expect(cluster.details[:occurrence_count]).to eq(3)
        expect(cluster.details[:provider_failure_categories]).to eq({})
      end

      it "normalizes similar error messages" do
        create(:agent_run, :failed, project: project, goal: "enhance_issue",
          error_message: "Timeout after 120s for run abc12345", completed_at: Time.current)
        create(:agent_run, :failed, project: project, goal: "enhance_issue",
          error_message: "Timeout after 300s for run def67890", completed_at: Time.current)
        create(:agent_run, :failed, project: project, goal: "enhance_issue",
          error_message: "Timeout after 60s for run ghi11111", completed_at: Time.current)

        result = described_class.call(account: account)

        cluster = result.find { |p| p.type == :error_cluster }
        expect(cluster).to be_present
        expect(cluster.details[:occurrence_count]).to eq(3)
      end

      it "keeps distinct error clusters for the same goal" do
        create_list(:agent_run, 3, :failed, project: project, goal: "enhance_issue",
          error_message: "GitHub API error: 403 Forbidden", completed_at: Time.current)
        create_list(:agent_run, 3, :failed, project: project, goal: "enhance_issue",
          error_message: "Container error: OCI runtime exec format error", completed_at: Time.current)

        result = described_class.call(account: account)

        clusters = result.select { |p| p.type == :error_cluster }
        expect(clusters.size).to eq(2)
        expect(clusters.map { |pattern| pattern.details[:error_pattern] }).to contain_exactly(
          "GitHub API error: <N> Forbidden",
          "Container error: OCI runtime exec format error"
        )
      end

      it "includes a redacted evidence bundle assembled from attempts, logs, config, and aggregate stats" do
        cluster = build_evidence_cluster
        expect(cluster).to be_present
        expect_redacted_evidence_bundle(cluster.details[:evidence_bundle])
      end

      it "loads stdout and stderr tails for sampled runs in one query" do
        runs = create_list(
          :agent_run,
          3,
          :failed,
          project: project,
          goal: "enhance_issue",
          error_message: "All runners exhausted: Codex, Claude",
          completed_at: Time.current
        )

        runs.each do |run|
          create(:agent_run_log, agent_run: run, log_type: "stdout", content: "stdout line")
          create(:agent_run_log, agent_run: run, log_type: "stderr", content: "stderr line")
        end

        detector = described_class.new(account: account)

        expect(count_queries { detector.send(:log_tail_evidence, runs) }).to eq(1)
      end

      it "reuses cached log tails when the same sampled runs are inspected again" do
        runs = create_list(
          :agent_run,
          3,
          :failed,
          project: project,
          goal: "enhance_issue",
          error_message: "All runners exhausted: Codex, Claude",
          completed_at: Time.current
        )

        runs.each do |run|
          create(:agent_run_log, agent_run: run, log_type: "stdout", content: "stdout line")
          create(:agent_run_log, agent_run: run, log_type: "stderr", content: "stderr line")
        end

        detector = described_class.new(account: account)
        detector.send(:log_tail_evidence, runs)

        expect(count_queries { detector.send(:log_tail_evidence, runs.reverse) }).to eq(0)
      end

      it "limits each sampled log tail to the most recent lines in SQL order" do
        run = create(
          :agent_run,
          :failed,
          project: project,
          goal: "enhance_issue",
          error_message: "All runners exhausted: Codex, Claude",
          completed_at: Time.current
        )

        25.times do |index|
          create(:agent_run_log, agent_run: run, log_type: "stdout", content: "stdout line #{index}")
        end

        detector = described_class.new(account: account)
        tails = detector.send(:log_tail_evidence, [ run ])

        expect(tails).to contain_exactly(
          include(
            run_id: run.id,
            stdout: (5..24).map { |index| "stdout line #{index}" }.join("\n")
          )
        )
      end

      def create_provider_exhaustion_run(error_message, failure_log_count: 1)
        run = create(:agent_run, :failed, project: project, goal: "analyze_issue",
          error_message: error_message, completed_at: Time.current)
        create_list(:agent_run_log, failure_log_count, :system, agent_run: run, content: "token expired",
          metadata: {
            type: AgentRunLog::PROVIDER_FAILURE_TYPE,
            provider: "ignored-for-clustering",
            failure_category: "auth_expired"
          })
        run
      end

      def build_evidence_cluster
        runs = create_list(
          :agent_run,
          3,
          :failed,
          project: project,
          runner: evidence_runner,
          goal: "enhance_issue",
          error_message: "All runners exhausted: Codex, Claude",
          runners_attempted: fixture_attempts,
          completed_at: Time.current
        )

        runs.each do |run|
          create(:agent_run_log, agent_run: run, log_type: "stdout",
            content: "Provider says Bearer sk-live-secret-token is invalid")
          create(:agent_run_log, agent_run: run, log_type: "stderr",
            content: "GitHub helper used github_pat_abcdefghijklmnopqrstuvwxyz1234567890")
        end

        described_class.call(account: account).find { |pattern| pattern.type == :error_cluster }
      end

      def expect_redacted_evidence_bundle(bundle)
        expect(bundle[:outer_errors]).to include("All runners exhausted: Codex, Claude")
        expect(bundle[:runner_attempts].first).to include(
          runner: "runner:42",
          error_type: "provider_error",
          error_message: "Model metadata for `gpt-4o` not found"
        )
        expect(bundle[:runner_attempts].first[:diagnostics].to_json).to include("[REDACTED:api_key]")
        expect(bundle[:runner_attempts].first[:diagnostics].to_json).not_to include("github_pat_abcdefghijklmnopqrstuvwxyz1234567890")
        expect(bundle[:log_tails].first[:stdout]).to include("[REDACTED:api_key]")
        expect(bundle[:log_tails].first[:stderr]).to include("[REDACTED:github_token]")
        expect(bundle[:runner_configs]).to contain_exactly(
          {
            runner_key: "kilocode",
            auth_type: "api_key",
            tier_model_ids: { low: "gpt-4o", mid: "gpt-4o", high: "gpt-4o" },
            provider_api_key_configured: true
          }
        )
        expect(bundle[:aggregate_stats]).to include(
          run_count: 3,
          distinct_runners: contain_exactly("runner:42")
        )
      end
    end

    context "with multiple goal types" do
      it "detects patterns independently per goal" do
        create_list(:agent_run, 3, :failed, project: project, goal: "enhance_issue",
          error_message: "Error A", completed_at: Time.current)
        create_list(:agent_run, 2, :completed, project: project, goal: "create_pr",
          completed_at: Time.current)

        result = described_class.call(account: account)

        expect(result.all? { |p| p.goal == "enhance_issue" }).to be true
      end
    end

    context "with patterns from different accounts" do
      it "only detects patterns for the specified account" do
        other_account = create(:account)
        other_project = create(:project, account: other_account)
        create_list(:agent_run, 3, :failed, project: other_project, goal: "enhance_issue",
          error_message: "Error", completed_at: Time.current)

        result = described_class.call(account: account)

        expect(result).to eq([])
      end
    end

    context "with duplicate pattern types" do
      it "returns at most one pattern per type per goal" do
        create_list(:agent_run, 5, :failed, project: project, goal: "enhance_issue",
          error_message: "No LLM provider produced an issue enhancement",
          completed_at: Time.current)

        result = described_class.call(account: account)

        types_by_goal = result.group_by { |p| [ p.type, p.goal ] }
        types_by_goal.each do |key, patterns|
          next if key.first == :error_cluster

          expect(patterns.size).to eq(1), "Expected 1 pattern for #{key}, got #{patterns.size}"
        end
      end
    end
  end

  describe ".call", :no_db do
    let(:account) { Struct.new(:id).new(1) }
    let(:run_class) { Struct.new(:id, :goal, :status, :error_message, :completed_at) }

    it "clusters failures that differ only by mixed alphanumeric identifiers" do
      runs = [
        run_class.new(1, "enhance_issue", "failed", "Timeout after 120s for run abc12345", 3.minutes.ago),
        run_class.new(2, "enhance_issue", "failed", "Timeout after 300s for run def67890", 2.minutes.ago),
        run_class.new(3, "enhance_issue", "failed", "Timeout after 60s for run ghi11111", 1.minute.ago)
      ]

      detector = described_class.new(account: account)
      allow(detector).to receive_messages(
        fetch_recent_finished_runs: runs,
        load_baseline_rate: nil
      )

      result = detector.call

      cluster = result.find { |pattern| pattern.type == :error_cluster }
      expect(cluster).to be_present
      expect(cluster.details[:occurrence_count]).to eq(3)
      expect(cluster.details[:error_pattern]).to include("run <ID>")
    end

    it "breaks a streak deterministically when equal timestamps include a newer success" do
      completed_at = Time.current
      runs = [
        run_class.new(3, "enhance_issue", "failed", "Error", completed_at),
        run_class.new(2, "enhance_issue", "completed", nil, completed_at),
        run_class.new(1, "enhance_issue", "failed", "Error", completed_at)
      ]

      detector = described_class.new(account: account)
      allow(detector).to receive_messages(
        fetch_recent_finished_runs: runs,
        load_baseline_rate: nil
      )

      result = detector.call

      expect(result.find { |pattern| pattern.type == :failure_streak }).to be_nil
    end

    it "returns patterns in a deterministic order for equal-severity matches" do
      detector = described_class.new(account: account)
      allow(detector).to receive_messages(
        fetch_recent_finished_runs: deterministic_runs,
        load_baseline_rate: nil
      )

      result = detector.call

      expect(result.map { |pattern| [ pattern.goal, pattern.type ] }).to eq(
        [
          [ "create_pr", :error_cluster ],
          [ "create_pr", :failure_streak ],
          [ "enhance_issue", :error_cluster ],
          [ "enhance_issue", :failure_streak ]
        ]
      )
    end

    it "changes the fingerprint when the candidate project set changes" do
      first = fingerprint_for(project_ids: [ 7 ], runner_ids: [ 42 ])
      second = fingerprint_for(project_ids: [ 8 ], runner_ids: [ 42 ])

      expect(first[:fingerprint]).not_to eq(second[:fingerprint])
    end

    def deterministic_runs
      [
        run_class.new(1, "enhance_issue", "failed", "No LLM provider produced an issue enhancement", 30.seconds.ago),
        run_class.new(2, "enhance_issue", "failed", "No LLM provider produced an issue enhancement", 20.seconds.ago),
        run_class.new(3, "enhance_issue", "failed", "No LLM provider produced an issue enhancement", 10.seconds.ago),
        run_class.new(4, "create_pr", "failed", "GitHub API error: 403 Forbidden", 3.minutes.ago),
        run_class.new(5, "create_pr", "failed", "GitHub API error: 403 Forbidden", 2.minutes.ago),
        run_class.new(6, "create_pr", "failed", "GitHub API error: 403 Forbidden", 1.minute.ago)
      ]
    end

    def fingerprint_for(project_ids:, runner_ids:)
      described_class.new(account: account).send(
        :with_fingerprint,
        goal: "enhance_issue",
        type: :error_cluster,
        error_pattern: "GitHub API error: <N> Forbidden",
        sample_messages: [ "GitHub API error: 403 Forbidden" ],
        evidence_bundle: {
          aggregate_stats: {
            distinct_project_ids: project_ids,
            distinct_runner_ids: runner_ids
          }
        }
      )
    end
  end
end
