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
end
