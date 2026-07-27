# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::IssueRunnerFailureHistory do
  subject(:call) { described_class.call(agent_run: current_run) }

  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:current_run) { create(:agent_run, project: project, issue: issue, goal: "create_pr") }

  context "when the run has no issue" do
    let(:current_run) { create(:agent_run, :with_custom_prompt, project: project, issue: nil) }

    it "returns an empty hash" do
      expect(call).to eq({})
    end
  end

  context "when there are no prior runs for the issue" do
    it "returns an empty hash" do
      expect(call).to eq({})
    end
  end

  context "when prior runs have no runners_attempted" do
    before do
      create(:agent_run, :failed, project: project, issue: issue, goal: "create_pr",
        runners_attempted: [])
    end

    it "returns an empty hash" do
      expect(call).to eq({})
    end
  end

  context "when prior runs have execution failures" do
    before do
      create(:agent_run, :failed, project: project, issue: issue, goal: "create_pr",
        runners_attempted: [
          { "runner" => "claude_code", "success" => false, "error_type" => "error" },
          { "runner" => "codex", "success" => false, "error_type" => "timeout" }
        ])
    end

    it "counts failures per canonical runner key" do
      expect(call).to eq("claude" => 1, "codex" => 1)
    end

    it "normalizes claude_code to claude via AGENT_TYPE_TO_RUNNER" do
      expect(call.keys).to include("claude")
      expect(call.keys).not_to include("claude_code")
    end
  end

  context "when prior runs have routing-key attempt labels" do
    let(:owner) { project.effective_owner }

    before do
      runner = create(:runner, user: owner, runner_key: "claude", auth_type: "api_key",
        provider_api_key: create(:provider_api_key, user: owner, api_service_type: "anthropic"))
      create(:agent_run, :failed, project: project, issue: issue, goal: "create_pr",
        runners_attempted: [
          { "runner" => runner.routing_key, "success" => false, "error_type" => "error" }
        ])
    end

    it "extracts the runner key from the routing key" do
      expect(call).to eq("claude" => 1)
    end
  end

  context "when prior runs have legacy provider routing-key labels" do
    let(:owner) { project.effective_owner }

    before do
      runner = create(:runner, user: owner, runner_key: "codex")
      create(:agent_run, :failed, project: project, issue: issue, goal: "create_pr",
        runners_attempted: [
          { "runner" => runner.legacy_routing_key, "success" => false, "error_type" => "error" }
        ])
    end

    it "extracts the runner key from the legacy provider routing key" do
      expect(call).to eq("codex" => 1)
    end
  end

  context "when prior runs include transient/non-execution failures" do
    before do
      create(:agent_run, :failed, project: project, issue: issue, goal: "create_pr",
        runners_attempted: [
          { "runner" => "claude_code", "success" => false, "error_type" => "rate_limited" },
          { "runner" => "claude_code", "success" => false, "error_type" => "unavailable" },
          { "runner" => "claude_code", "success" => false, "error_type" => "cancelled_by_cleanup" },
          { "runner" => "codex", "success" => false, "error_type" => "error" }
        ])
    end

    it "excludes rate_limited, unavailable, and cancelled_by_cleanup" do
      expect(call).to eq("codex" => 1)
      expect(call).not_to have_key("claude")
    end
  end

  context "when prior runs have successful attempts" do
    before do
      create(:agent_run, :failed, project: project, issue: issue, goal: "create_pr",
        runners_attempted: [
          { "runner" => "claude_code", "success" => true },
          { "runner" => "codex", "success" => false, "error_type" => "error" }
        ])
    end

    it "only counts failures, not successes" do
      expect(call).to eq("codex" => 1)
      expect(call).not_to have_key("claude")
    end
  end

  context "when multiple prior runs accumulate failures for the same runner" do
    before do
      2.times do
        create(:agent_run, :failed, project: project, issue: issue, goal: "create_pr",
          runners_attempted: [
            { "runner" => "claude_code", "success" => false, "error_type" => "error" }
          ])
      end
      create(:agent_run, :failed, project: project, issue: issue, goal: "create_pr",
        runners_attempted: [
          { "runner" => "claude_code", "success" => false, "error_type" => "timeout" }
        ])
    end

    it "accumulates failure counts across multiple runs" do
      expect(call).to eq("claude" => 3)
    end
  end

  context "when runs for a different goal exist" do
    before do
      create(:agent_run, :failed, project: project, issue: issue, goal: "enhance_issue",
        runners_attempted: [
          { "runner" => "claude_code", "success" => false, "error_type" => "error" }
        ])
    end

    it "ignores runs with a different goal" do
      expect(call).to eq({})
    end
  end

  context "when runs for a different issue exist" do
    before do
      other_issue = create(:issue, project: project)
      create(:agent_run, :failed, project: project, issue: other_issue, goal: "create_pr",
        runners_attempted: [
          { "runner" => "claude_code", "success" => false, "error_type" => "error" }
        ])
    end

    it "ignores runs for a different issue" do
      expect(call).to eq({})
    end
  end

  context "when the current run itself has failures in runners_attempted" do
    before do
      # Ensure a separate prior run also exists so the query doesn't trivially return {}
      create(:agent_run, :failed, project: project, issue: issue, goal: "create_pr",
        runners_attempted: [
          { "runner" => "codex", "success" => false, "error_type" => "error" }
        ])
      current_run.update!(
        runners_attempted: [
          { "runner" => "claude_code", "success" => false, "error_type" => "error" }
        ]
      )
    end

    it "excludes the current run from the failure history" do
      expect(call).not_to have_key("claude")
      expect(call).to eq("codex" => 1)
    end
  end

  context "with all execution failure types" do
    before do
      create(:agent_run, :failed, project: project, issue: issue, goal: "create_pr",
        runners_attempted: [
          { "runner" => "claude_code", "success" => false, "error_type" => "error" },
          { "runner" => "codex", "success" => false, "error_type" => "timeout" },
          { "runner" => "cursor", "success" => false, "error_type" => "infinite_loop" },
          { "runner" => "gemini", "success" => false, "error_type" => "preflight_timeout" }
        ])
    end

    it "counts all execution failure types" do
      expect(call).to eq("claude" => 1, "codex" => 1, "cursor" => 1, "gemini" => 1)
    end
  end
end
