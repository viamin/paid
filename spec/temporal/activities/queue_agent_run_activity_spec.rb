# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::QueueAgentRunActivity do
  include ActiveJob::TestHelper

  let(:activity) { described_class.new }
  let(:user) { create(:user) }
  let(:project) { create(:project, account: user.account, created_by: user) }
  let(:issue) { create(:issue, project: project) }

  describe "#execute" do
    around do |example|
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      clear_enqueued_jobs
      clear_performed_jobs
      example.run
    ensure
      clear_enqueued_jobs
      clear_performed_jobs
      ActiveJob::Base.queue_adapter = original_adapter
    end

    it "creates an agent run with queued status" do
      result = activity.execute(project_id: project.id, issue_id: issue.id)

      expect(result[:agent_run_id]).to be_present
      expect(result[:queued]).to be true
      expect(ProcessRunQueueJob).to have_been_enqueued

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.status).to eq("queued")
      expect(agent_run.project).to eq(project)
      expect(agent_run.issue).to eq(issue)
      expect(agent_run.agent_type).to eq("claude_code")
      expect(agent_run.runner).to eq(user.runners.find_by!(runner_key: "claude"))
    end

    it "accepts a custom agent_type" do
      result = activity.execute(project_id: project.id, issue_id: issue.id, agent_type: "aider")

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.agent_type).to eq("aider")
      expect(agent_run.runner_id).to be_nil
    end

    it "accepts copilot when a requested agent_type is container executable" do
      result = activity.execute(project_id: project.id, issue_id: issue.id, agent_type: "copilot")

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.runner_id).to be_nil
      expect(agent_run.agent_type).to eq("copilot")
    end

    it "derives agent_type from runner_id when only a runner is supplied" do
      codex_runner = user.runners.find_or_create_by!(runner_key: "codex", auth_type: "subscription")

      result = activity.execute(project_id: project.id, issue_id: issue.id, runner_id: codex_runner.id)

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.runner).to eq(codex_runner)
      expect(agent_run.agent_type).to eq("codex")
    end

    it "accepts copilot when a requested runner_id is container executable" do
      copilot_runner = user.runners.find_or_create_by!(runner_key: "copilot", auth_type: "subscription")

      result = activity.execute(project_id: project.id, issue_id: issue.id, runner_id: copilot_runner.id)

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.runner).to eq(copilot_runner)
      expect(agent_run.agent_type).to eq("copilot")
    end

    it "falls back to the runnable default when a requested runner is treated as non-executable" do
      copilot_runner = user.runners.find_or_create_by!(runner_key: "copilot", auth_type: "subscription")
      allow(RunnerSupport).to receive(:container_executable_runner_key?).and_call_original
      allow(RunnerSupport).to receive(:container_executable_runner_key?).with("copilot").and_return(false)

      result = activity.execute(project_id: project.id, issue_id: issue.id, runner_id: copilot_runner.id)

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.runner).to eq(user.runners.find_by!(runner_key: "claude"))
      expect(agent_run.agent_type).to eq("claude_code")
    end

    it "uses the configured primary runner when agent type is omitted" do
      codex_runner = user.runners.find_or_create_by!(runner_key: "codex", auth_type: "subscription")
      user.settings.update!(default_agent_runner: codex_runner.routing_key)

      result = activity.execute(project_id: project.id, issue_id: issue.id)

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.runner).to eq(codex_runner)
      expect(agent_run.agent_type).to eq("codex")
    end

    it "records a runner selection decision for queued runs" do
      codex_runner = user.runners.find_or_create_by!(runner_key: "codex", auth_type: "subscription")
      user.settings.update!(default_agent_runner: codex_runner.routing_key)

      result = activity.execute(project_id: project.id, issue_id: issue.id)

      agent_run = AgentRun.find(result[:agent_run_id])
      decision = agent_run.orchestration_decisions.where(decision_type: "select_agent").find_by(actor: "provider_selection")

      expect(decision).to be_present
      expect(decision.context["decision_status"]).to eq("applied")
      expect(decision.outputs).to include(
        "outcome" => "selected",
        "selection" => include(
          "runner_id" => codex_runner.id,
          "provider_key" => "codex",
          "agent_type" => "codex"
        )
      )
      expect(decision.inputs.dig("policy_constraints", "default_agent_runner")).to eq(codex_runner.routing_key)
    end

    it "uses the tenant API key runner for the default runner" do
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
      create(:tenant_setting, account: user.account,
        provider_preferences: { "api_key_ids" => { "anthropic" => api_key.id.to_s } })

      result = activity.execute(project_id: project.id, issue_id: issue.id)

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.runner).to have_attributes(
        runner_key: "claude",
        auth_type: "api_key",
        provider_api_key_id: api_key.id
      )
      expect(agent_run.agent_type).to eq("claude_code")
    end

    it "uses the goal-specific runner when goal is review" do
      codex_runner = user.runners.find_or_create_by!(runner_key: "codex", auth_type: "subscription")
      user.settings.update!(default_agent_runners_by_goal: { "review" => codex_runner.routing_key })

      result = activity.execute(project_id: project.id, source_pull_request_number: 42, goal: "review")

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.runner).to eq(codex_runner)
      expect(agent_run.agent_type).to eq("codex")
    end

    it "stores custom_prompt and source_pull_request_number" do
      result = activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        custom_prompt: "Fix the bug",
        source_pull_request_number: 42
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.custom_prompt).to eq("Fix the bug")
      expect(agent_run.source_pull_request_number).to eq(42)
    end

    it "stores the goal parameter on the created agent run" do
      result = activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        source_pull_request_number: 42,
        goal: "review"
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.goal).to eq("review")
    end

    it "inherits manual priority from the latest unsuccessful PR run" do
      create(:agent_run, :timeout,
        project: project,
        issue: issue,
        source_pull_request_number: 42,
        goal: "create_pr",
        trigger_type: "manual",
        completed_at: 5.minutes.ago)

      result = activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        source_pull_request_number: 42,
        goal: "create_pr"
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.trigger_type).to eq("manual")
    end

    it "does not inherit manual priority from a successful PR run" do
      create(:agent_run, :completed,
        project: project,
        issue: issue,
        source_pull_request_number: 42,
        goal: "create_pr",
        trigger_type: "manual",
        completed_at: 5.minutes.ago)

      result = activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        source_pull_request_number: 42,
        goal: "create_pr"
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.trigger_type).to eq("automatic")
    end

    it "stores the focus parameter on the created agent run" do
      result = activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        focus: "review_feedback"
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.focus).to eq("review_feedback")
    end

    it "defaults goal to create_pr when not specified" do
      result = activity.execute(
        project_id: project.id,
        issue_id: issue.id
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.goal).to eq("create_pr")
    end

    it "uses the tenant default goal when goal is not specified" do
      create(:tenant_setting, account: user.account, agent_settings: { "default_goal" => "review" })

      result = activity.execute(
        project_id: project.id,
        source_pull_request_number: 42
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.goal).to eq("review")
    end

    it "persists draft review round tracking metadata" do
      result = activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        count_toward_draft_review_round: true,
        expected_draft_review_count: 2
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.count_toward_draft_review_round).to be(true)
      expect(agent_run.expected_draft_review_count).to eq(2)
    end

    it "requires expected_draft_review_count when tracking draft review rounds" do
      expect {
        activity.execute(
          project_id: project.id,
          issue_id: issue.id,
          count_toward_draft_review_round: true
        )
      }.to raise_error(ActiveRecord::RecordInvalid, /expected draft review count/i)
    end

    it "works without an issue" do
      result = activity.execute(
        project_id: project.id,
        custom_prompt: "Do something"
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.issue).to be_nil
      expect(agent_run.custom_prompt).to eq("Do something")
    end

    it "skips create_pr runs for untrusted issues" do
      untrusted_issue = create(:issue, project: project, github_creator_login: "dependabot[bot]")

      result = activity.execute(project_id: project.id, issue_id: untrusted_issue.id, goal: "create_pr")

      expect(result).to eq(queued: false, skipped: true, reason: "untrusted_issue")
      expect(AgentRun.where(project: project, issue: untrusted_issue)).to be_empty
      expect(ProcessRunQueueJob).not_to have_been_enqueued
    end

    it "allows create_pr follow-up runs on untrusted PRs (source_pull_request_number set)" do
      untrusted_pr = create(:issue, project: project, is_pull_request: true,
        github_creator_login: "dependabot[bot]")

      result = activity.execute(
        project_id: project.id,
        issue_id: untrusted_pr.id,
        source_pull_request_number: untrusted_pr.github_number,
        goal: "create_pr",
        focus: "merge_conflict"
      )

      expect(result[:queued]).to be true
      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.source_pull_request_number).to eq(untrusted_pr.github_number)
      expect(agent_run.focus).to eq("merge_conflict")
      expect(ProcessRunQueueJob).to have_been_enqueued
    end

    context "when a duplicate run exists" do
      it "returns existing run when a queued run exists for the same issue" do
        existing = create(:agent_run, :queued, project: project, issue: issue)

        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:agent_run_id]).to eq(existing.id)
        expect(result[:duplicate]).to be true
        expect(AgentRun.where(project: project, issue: issue).count).to eq(1)
        expect(ProcessRunQueueJob).not_to have_been_enqueued
      end

      it "returns existing run when an active run exists for the same issue" do
        existing = create(:agent_run, :running, project: project, issue: issue)

        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:agent_run_id]).to eq(existing.id)
        expect(result[:duplicate]).to be true
        expect(ProcessRunQueueJob).not_to have_been_enqueued
      end

      it "merges draft review round tracking into an existing duplicate run" do
        existing = create(:agent_run, :queued, project: project, issue: issue)

        result = activity.execute(
          project_id: project.id,
          issue_id: issue.id,
          count_toward_draft_review_round: true,
          expected_draft_review_count: 5
        )

        expect(result[:agent_run_id]).to eq(existing.id)
        expect(result[:duplicate]).to be true
        expect(existing.reload.count_toward_draft_review_round).to be(true)
        expect(existing.expected_draft_review_count).to eq(5)
      end

      it "merges draft review round tracking into an existing active duplicate run" do
        existing = create(:agent_run, :running, project: project, issue: issue)

        result = activity.execute(
          project_id: project.id,
          issue_id: issue.id,
          count_toward_draft_review_round: true,
          expected_draft_review_count: 5
        )

        expect(result[:agent_run_id]).to eq(existing.id)
        expect(result[:duplicate]).to be true
        expect(existing.reload.count_toward_draft_review_round).to be(true)
        expect(existing.expected_draft_review_count).to eq(5)
      end

      it "returns existing run when a queued run exists for the same PR" do
        existing = create(:agent_run, :queued, project: project,
          source_pull_request_number: 42, custom_prompt: "Fix it")

        result = activity.execute(
          project_id: project.id,
          source_pull_request_number: 42,
          custom_prompt: "Fix it again"
        )

        expect(result[:agent_run_id]).to eq(existing.id)
        expect(result[:duplicate]).to be true
        expect(ProcessRunQueueJob).not_to have_been_enqueued
      end

      it "allows queueing when no active/queued run exists for the issue" do
        create(:agent_run, :completed, project: project, issue: issue)

        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:queued]).to be true
        expect(result[:duplicate]).to be_nil
      end

      it "detects duplicate review-goal runs against the same PR" do
        existing = create(:agent_run, :queued, project: project,
          source_pull_request_number: 42, goal: "review")

        result = activity.execute(
          project_id: project.id,
          source_pull_request_number: 42,
          goal: "review"
        )

        expect(result[:agent_run_id]).to eq(existing.id)
        expect(result[:duplicate]).to be true
      end

      it "skips queueing a review run when a create_pr run is active for the same PR" do
        existing = create(:agent_run, :running, project: project,
          source_pull_request_number: 42, goal: "create_pr")

        result = activity.execute(
          project_id: project.id,
          source_pull_request_number: 42,
          goal: "review"
        )

        expect(result[:agent_run_id]).to eq(existing.id)
        expect(result[:duplicate]).to be true
      end

      it "skips queueing a create_pr run when a review run is active for the same issue" do
        existing = create(:agent_run, :running, project: project, issue: issue,
          source_pull_request_number: 42, goal: "review")

        result = activity.execute(project_id: project.id, issue_id: issue.id, goal: "create_pr")

        expect(result[:agent_run_id]).to eq(existing.id)
        expect(result[:duplicate]).to be true
      end

      it "does not merge draft review tracking onto an existing run with a different goal" do
        existing = create(:agent_run, :running, project: project, issue: issue, goal: "create_pr")

        result = activity.execute(
          project_id: project.id,
          issue_id: issue.id,
          goal: "review",
          count_toward_draft_review_round: true,
          expected_draft_review_count: 5
        )

        expect(result[:duplicate]).to be true
        expect(existing.reload.count_toward_draft_review_round).to be(false)
        expect(existing.expected_draft_review_count).to be_nil
      end
    end

    it "creates a review-goal agent run when goal is review" do
      result = activity.execute(
        project_id: project.id,
        source_pull_request_number: 42,
        goal: "review"
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.goal).to eq("review")
      expect(agent_run.source_pull_request_number).to eq(42)
    end

    # Regression coverage for PR #1077. When a caller targets a PR the goal
    # must be explicit in the call site so initial-sync paths cannot silently
    # queue a default create_pr run for an existing PR. These tests pin the
    # outputs of each explicit goal alongside a source_pull_request_number so
    # that a future refactor relying on the activity-level default is caught.
    describe "#1077 regression: PR-originated runs carry the caller's explicit goal" do
      it "records goal=review on the created run when the caller passes goal: 'review'" do
        result = activity.execute(
          project_id: project.id,
          source_pull_request_number: 42,
          goal: "review"
        )

        agent_run = AgentRun.find(result[:agent_run_id])
        expect(agent_run.goal).to eq("review")
        expect(agent_run.source_pull_request_number).to eq(42)
      end

      it "records goal=create_pr on the created run when the caller passes goal: 'create_pr'" do
        result = activity.execute(
          project_id: project.id,
          issue_id: issue.id,
          source_pull_request_number: 42,
          goal: "create_pr"
        )

        agent_run = AgentRun.find(result[:agent_run_id])
        expect(agent_run.goal).to eq("create_pr")
        expect(agent_run.source_pull_request_number).to eq(42)
      end

      it "deduplicates review-goal PR runs against any in-flight run for the same PR" do
        existing = create(:agent_run, :running, project: project,
          source_pull_request_number: 42, goal: "create_pr")

        result = activity.execute(
          project_id: project.id,
          source_pull_request_number: 42,
          goal: "review"
        )

        # Two runs against the same PR share a branch/worktree, so the second
        # is deduplicated regardless of goal — the poller re-evaluates next cycle.
        expect(result[:agent_run_id]).to eq(existing.id)
        expect(result[:duplicate]).to be true
      end
    end
  end
end
