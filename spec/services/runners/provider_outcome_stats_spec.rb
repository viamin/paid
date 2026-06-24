# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::ProviderOutcomeStats do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  describe ".call" do
    subject(:stats) { described_class.call(account: account, time_range: "30d") }

    context "with no agent runs" do
      it "returns an empty array" do
        expect(stats).to eq([])
      end
    end

    context "with completed and failed runs" do
      before do
        travel_to 5.days.ago do
          create(:agent_run, :completed, project: project, agent_type: "claude_code")
          create(:agent_run, :completed, project: project, agent_type: "claude_code")
          create(:agent_run, :failed, project: project, agent_type: "claude_code")
          create(:agent_run, :completed, project: project, agent_type: "codex")
        end
      end

      it "returns one entry per provider, ordered by total runs descending" do
        providers = stats.map { |e| e[:provider] }
        expect(providers.first).to eq("claude")
        expect(providers).to include("codex")
      end

      it "counts total runs per provider" do
        claude_entry = stats.find { |e| e[:provider] == "claude" }
        expect(claude_entry[:total_runs]).to eq(3)
      end

      it "counts completed runs per provider" do
        claude_entry = stats.find { |e| e[:provider] == "claude" }
        expect(claude_entry[:completed]).to eq(2)
      end

      it "calculates completion rate" do
        claude_entry = stats.find { |e| e[:provider] == "claude" }
        expect(claude_entry[:completion_rate]).to eq(66.7)
      end

      it "includes series data for all tracked statuses" do
        claude_entry = stats.find { |e| e[:provider] == "claude" }
        series_names = claude_entry[:series].map { |s| s[:name] }
        expect(series_names).to include("Completed", "Failed")
      end

      it "includes the correct colors array" do
        claude_entry = stats.find { |e| e[:provider] == "claude" }
        expect(claude_entry[:colors]).to eq(
          described_class::TRACKED_STATUSES.map { |s| described_class::STATUS_COLORS[s] }
        )
      end
    end

    context "with runs outside the time range" do
      before do
        travel_to 35.days.ago do
          create(:agent_run, :completed, project: project, agent_type: "claude_code")
        end
        travel_to 5.days.ago do
          create(:agent_run, :failed, project: project, agent_type: "claude_code")
        end
      end

      it "excludes runs outside the time window" do
        claude_entry = stats.find { |e| e[:provider] == "claude" }
        expect(claude_entry[:total_runs]).to eq(1)
        expect(claude_entry[:completed]).to eq(0)
      end
    end

    context "with cumulative time range" do
      subject(:stats) { described_class.call(account: account, time_range: "cumulative") }

      before do
        travel_to 60.days.ago do
          create(:agent_run, :completed, project: project, agent_type: "claude_code")
        end
        travel_to 5.days.ago do
          create(:agent_run, :completed, project: project, agent_type: "claude_code")
        end
      end

      it "includes all runs regardless of date" do
        claude_entry = stats.find { |e| e[:provider] == "claude" }
        expect(claude_entry[:total_runs]).to eq(2)
      end
    end

    context "with runs for a non-create_pr goal" do
      before do
        travel_to 5.days.ago do
          create(:agent_run, :completed, :review_goal, project: project, agent_type: "claude_code")
        end
      end

      it "excludes non-create_pr runs" do
        expect(stats).to eq([])
      end
    end

    context "with runs from another account" do
      before do
        other_project = create(:project, account: create(:account))
        travel_to 5.days.ago do
          create(:agent_run, :completed, project: other_project, agent_type: "claude_code")
        end
      end

      it "does not include other account runs" do
        expect(stats).to eq([])
      end
    end

    context "with queued/running runs (no completed_at)" do
      before do
        create(:agent_run, :running, project: project, agent_type: "claude_code")
        create(:agent_run, :queued, project: project, agent_type: "claude_code")
      end

      it "excludes unfinished runs with no completed_at" do
        expect(stats).to eq([])
      end
    end

    context "with multiple statuses" do
      before do
        travel_to 3.days.ago do
          create(:agent_run, :completed, project: project, agent_type: "codex")
          create(:agent_run, :timeout, project: project, agent_type: "codex")
          create(:agent_run, :no_output, project: project, agent_type: "codex")
          create(:agent_run, :auth_expired, project: project, agent_type: "codex")
          create(:agent_run, :rate_limited, project: project, agent_type: "codex")
          create(:agent_run, :cancelled, project: project, agent_type: "codex")
        end
      end

      it "tracks all TRACKED_STATUSES" do
        codex_entry = stats.find { |e| e[:provider] == "codex" }
        expect(codex_entry[:total_runs]).to eq(6)
        expect(codex_entry[:completed]).to eq(1)
        expect(codex_entry[:completion_rate]).to eq(16.7)
      end

      it "populates series data with correct counts" do
        codex_entry = stats.find { |e| e[:provider] == "codex" }
        completed_series = codex_entry[:series].find { |s| s[:name] == "Completed" }
        expect(completed_series[:data].values.sum).to eq(1)

        timeout_series = codex_entry[:series].find { |s| s[:name] == "Timeout" }
        expect(timeout_series[:data].values.sum).to eq(1)
      end
    end

    context "with token_budget_exceeded runs" do
      before do
        travel_to 3.days.ago do
          create(:agent_run, :completed, project: project, agent_type: "codex")
          create(:agent_run, :token_budget_exceeded, project: project, agent_type: "codex")
        end
      end

      it "counts token_budget_exceeded runs toward the provider total" do
        codex_entry = stats.find { |e| e[:provider] == "codex" }
        expect(codex_entry[:total_runs]).to eq(2)
        expect(codex_entry[:completed]).to eq(1)
        expect(codex_entry[:completion_rate]).to eq(50.0)
      end

      it "exposes a series and color for token_budget_exceeded" do
        codex_entry = stats.find { |e| e[:provider] == "codex" }
        budget_series = codex_entry[:series].find { |s| s[:name] == "Token Budget Exceeded" }
        expect(budget_series[:data].values.sum).to eq(1)
        expect(codex_entry[:colors]).to include("#e11d48")
      end
    end

    context "with cached results" do
      around do |example|
        original_cache = Rails.cache
        Rails.cache = ActiveSupport::Cache::MemoryStore.new
        example.run
      ensure
        Rails.cache = original_cache
      end

      before do
        travel_to 5.days.ago do
          create(:agent_run, :completed, project: project, agent_type: "claude_code")
        end
      end

      it "returns cached data on subsequent calls" do
        first = described_class.call(account: account, time_range: "30d")
        expect(first.first[:total_runs]).to eq(1)

        travel_to 5.days.ago do
          create(:agent_run, :completed, project: project, agent_type: "claude_code")
        end

        cached = described_class.call(account: account, time_range: "30d")
        expect(cached.first[:total_runs]).to eq(1)
      end
    end

    context "with invalid time_range" do
      subject(:stats) { described_class.call(account: account, time_range: "invalid") }

      before do
        travel_to 5.days.ago do
          create(:agent_run, :completed, project: project, agent_type: "claude_code")
        end
      end

      it "falls back to 30d" do
        expect(stats.first[:total_runs]).to eq(1)
      end
    end
  end
end
