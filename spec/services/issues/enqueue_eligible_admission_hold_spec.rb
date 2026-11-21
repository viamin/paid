# frozen_string_literal: true

require "rails_helper"

# @spec EAGER-QUEUE-018 AGENT-RETRY-017
# Regression for the #4989 acceptance bypass: the shared auto-pick create_pr
# retry policy refuses implementation_work_produced, but ordinary issue
# admission (Issues::EnqueueEligible via sweeps, delayed re-enqueues, and
# sync-driven seeding) once still minted a fresh implementation attempt for
# the same issue (#4711 runs 30353 -> 30371).
RSpec.describe Issues::EnqueueEligible do
  include ActiveJob::TestHelper

  let(:project) { create(:project, auto_pick_enabled: true) }

  def failed_create_pr_run(issue:, **attrs)
    create(:agent_run, :failed, :automatic, project: project, issue: issue,
      goal: "create_pr", auto_pick: true, **attrs)
  end

  describe "ordinary admission after a produced-work failure" do
    it "refuses a fresh implementation attempt after observable main-agent work" do
      issue = create(:issue, project: project, paid_state: "failed", github_state: "open")
      failed_create_pr_run(issue: issue,
        runners_attempted: [ { "success" => true, "output_chars" => 250 } ])

      result = described_class.call(issue, project: project)

      expect(result).to be_nil
      expect(AgentRun.where(issue: issue, goal: "create_pr").count).to eq(1)
    end

    it "refuses a fresh implementation attempt after a pushed revision" do
      issue = create(:issue, project: project, paid_state: "failed", github_state: "open")
      failed_create_pr_run(issue: issue, result_commit_sha: "a" * 40)

      result = described_class.call(issue, project: project)

      expect(result).to be_nil
      expect(AgentRun.where(issue: issue, goal: "create_pr").count).to eq(1)
    end

    it "logs the hold with the shared refusal reason" do
      issue = create(:issue, project: project, paid_state: "failed", github_state: "open")
      failed_create_pr_run(issue: issue,
        runners_attempted: [ { "success" => true, "output_chars" => 250 } ])
      allow(Rails.logger).to receive(:info)

      described_class.call(issue, project: project)

      expect(Rails.logger).to have_received(:info).with(
        hash_including(
          message: "enqueue_eligible.implementation_work_held",
          issue_id: issue.id,
          hold_reason: "implementation_work_produced"
        )
      )
    end
  end

  describe "periodic sweep admission" do
    it "does not seed a run for an issue held by produced work" do
      issue = create(:issue, project: project, paid_state: "failed", github_state: "open")
      failed_create_pr_run(issue: issue,
        runners_attempted: [ { "success" => true, "output_chars" => 250 } ])

      expect {
        Issues::BulkEnqueueEligible.call(project: project)
      }.not_to change(AgentRun, :count)
    end
  end

  describe "in-place rate-limit recovery" do
    it "does not duplicate a rate-limited run that produced work while recovery pends" do
      issue = create(:issue, project: project, paid_state: "in_progress", github_state: "open")
      create(:agent_run, :rate_limited, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true,
        runners_attempted: [ { "success" => true, "output_chars" => 250 } ])

      result = described_class.call(issue, project: project)

      expect(result).to be_nil
      expect(AgentRun.where(issue: issue).count).to eq(1)
    end

    it "does not duplicate a rate-limited run without observable work while recovery pends" do
      issue = create(:issue, project: project, paid_state: "in_progress", github_state: "open")
      create(:agent_run, :rate_limited, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true)

      result = described_class.call(issue, project: project)

      expect(result).to be_nil
      expect(AgentRun.where(issue: issue).count).to eq(1)
    end
  end

  describe "authorized operator reset boundary" do
    it "re-arms ordinary admission once the failure predates the reset window" do
      issue = create(:issue, project: project, paid_state: "failed", github_state: "open")
      failed_create_pr_run(issue: issue, created_at: 2.hours.ago,
        runners_attempted: [ { "success" => true, "output_chars" => 250 } ])
      issue.abandon_due_to_runner_retry_cap!(reason: "Automated create_pr failed", cap: 1, runner_keys: [])
      issue.clear_runner_retry_abandonment!(window_reset_at: 1.hour.ago)

      expect {
        described_class.call(issue, project: project)
      }.to change(AgentRun, :count).by(1)
    end
  end

  describe "safe empty-work and sibling-goal paths" do
    it "still admits an empty-work create_pr failure through ordinary admission" do
      issue = create(:issue, project: project, paid_state: "failed", github_state: "open")
      failed_create_pr_run(issue: issue)

      expect {
        described_class.call(issue, project: project)
      }.to change(AgentRun, :count).by(1)
    end

    it "does not hold admission when the latest failed auto-pick run analyzed the issue" do
      issue = create(:issue, project: project, paid_state: "failed", github_state: "open")
      create(:agent_run, :failed, :automatic, project: project, issue: issue,
        goal: "analyze_issue", auto_pick: true,
        runners_attempted: [ { "success" => true, "output_chars" => 250 } ])

      expect {
        described_class.call(issue, project: project)
      }.to change(AgentRun, :count).by(1)
    end

    it "does not hold admission for a no_output source" do
      issue = create(:issue, project: project, paid_state: "failed", github_state: "open")
      create(:agent_run, :no_output, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true)

      expect {
        described_class.call(issue, project: project)
      }.to change(AgentRun, :count).by(1)
    end
  end

  describe "failure-callback convergence" do
    it "records the shared refusal without scheduling any re-enqueue for produced work" do
      issue = create(:issue, project: project, paid_state: "in_progress", github_state: "open")
      run = failed_create_pr_run(issue: issue,
        runners_attempted: [ { "success" => true, "output_chars" => 250 } ])

      expect {
        issue.update!(paid_state: "failed")
      }.not_to have_enqueued_job(Issues::ReenqueueEligibleJob)
      expect(enqueued_jobs.none? { |job| job[:job] == RetryFailedAutoPickCreatePrJob }).to be(true)

      decision = OrchestrationDecision.where(agent_run: run, decision_type: "auto_pick_create_pr_failed_run_retry").last
      expect(decision.outputs["reason"]).to eq("implementation_work_produced")
    end
  end
end
