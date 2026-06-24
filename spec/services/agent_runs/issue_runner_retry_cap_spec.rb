# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::IssueRunnerRetryCap do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:goal) { "create_pr" }
  let(:cap) { 3 }

  def record_failures(runner_key, count, error_type: "error")
    count.times do
      create(:agent_run, :failed, project: project, issue: issue, goal: goal,
        runners_attempted: [ { "runner" => runner_key, "success" => false, "error_type" => error_type } ])
    end
  end

  describe ".capped_runner_keys" do
    subject(:capped) do
      described_class.capped_runner_keys(project: project, issue: issue, goal: goal, cap: cap)
    end

    it "returns an empty set when no provider has reached the cap" do
      record_failures("claude_code", 2)
      expect(capped).to be_empty
    end

    it "includes a provider once it reaches the cap" do
      record_failures("claude_code", 3)
      expect(capped).to contain_exactly("claude")
    end

    it "only includes providers that reached the cap, leaving others out" do
      record_failures("claude_code", 3)
      record_failures("codex", 2)
      expect(capped).to contain_exactly("claude")
    end

    it "includes multiple providers when each reaches the cap" do
      record_failures("claude_code", 3)
      record_failures("codex", 3)
      expect(capped).to contain_exactly("claude", "codex")
    end

    it "counts execution failure types (error, timeout, infinite_loop, preflight_timeout)" do
      create(:agent_run, :failed, project: project, issue: issue, goal: goal,
        runners_attempted: [
          { "runner" => "claude_code", "success" => false, "error_type" => "error" },
          { "runner" => "claude_code", "success" => false, "error_type" => "timeout" },
          { "runner" => "claude_code", "success" => false, "error_type" => "infinite_loop" }
        ])
      expect(capped).to contain_exactly("claude")
    end

    it "ignores transient failures (rate_limited, unavailable, cancelled_by_cleanup)" do
      create(:agent_run, :failed, project: project, issue: issue, goal: goal,
        runners_attempted: [
          { "runner" => "claude_code", "success" => false, "error_type" => "rate_limited" },
          { "runner" => "claude_code", "success" => false, "error_type" => "unavailable" },
          { "runner" => "claude_code", "success" => false, "error_type" => "cancelled_by_cleanup" }
        ])
      expect(capped).to be_empty
    end

    it "is goal-scoped (ignores failures for a different goal)" do
      record_failures("claude_code", 5)
      expect(
        described_class.capped_runner_keys(project: project, issue: issue, goal: "analyze_issue", cap: cap)
      ).to be_empty
    end

    it "is issue-scoped (ignores failures for a different issue)" do
      other_issue = create(:issue, project: project)
      5.times do
        create(:agent_run, :failed, project: project, issue: other_issue, goal: goal,
          runners_attempted: [ { "runner" => "claude_code", "success" => false, "error_type" => "error" } ])
      end
      expect(capped).to be_empty
    end

    it "excludes the run passed via exclude_run_id" do
      excluded = create(:agent_run, :failed, project: project, issue: issue, goal: goal,
        runners_attempted: [ { "runner" => "claude_code", "success" => false, "error_type" => "error" } ])
      record_failures("claude_code", 2)

      result = described_class.capped_runner_keys(project: project, issue: issue, goal: goal,
        cap: cap, exclude_run_id: excluded.id)
      expect(result).to be_empty
    end

    context "with a non-positive cap" do
      let(:cap) { 0 }

      it "returns an empty set (cap disabled)" do
        record_failures("claude_code", 10)
        expect(capped).to be_empty
      end
    end

    context "when the issue is nil" do
      subject(:capped) do
        described_class.capped_runner_keys(project: project, issue: nil, goal: goal, cap: cap)
      end

      it "returns an empty set" do
        expect(capped).to be_empty
      end
    end
  end

  describe ".cap_reached?" do
    it "returns true when the provider reached the cap" do
      record_failures("claude_code", 3)
      expect(described_class.cap_reached?(project: project, issue: issue, goal: goal,
        runner_key: "claude", cap: cap)).to be true
    end

    it "returns false when the provider has not reached the cap" do
      record_failures("claude_code", 2)
      expect(described_class.cap_reached?(project: project, issue: issue, goal: goal,
        runner_key: "claude", cap: cap)).to be false
    end

    it "normalizes the claude_code agent type to claude" do
      record_failures("claude_code", 3)
      expect(described_class.cap_reached?(project: project, issue: issue, goal: goal,
        runner_key: "claude_code", cap: cap)).to be true
    end
  end
end
