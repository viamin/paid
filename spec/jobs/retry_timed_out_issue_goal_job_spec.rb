# frozen_string_literal: true

require "rails_helper"

RSpec.describe RetryTimedOutIssueGoalJob do
  # @spec AGENT-RETRY-014 AGENT-RETRY-015
  describe "#perform" do
    let(:project) { create(:project) }
    let(:issue) { create(:issue, project: project) }

    def create_timed_out_issue_goal_run(attrs = {})
      create(:agent_run, :timeout, :create_issue_goal,
        project: project, issue: issue, **attrs)
    end

    it "creates a new queued run for a timed-out issue goal run" do
      agent_run = create_timed_out_issue_goal_run

      expect { described_class.perform_now(agent_run.id) }
        .to change(AgentRun, :count).by(1)

      new_run = AgentRun.last
      expect(new_run.status).to eq("queued")
      expect(new_run.goal).to eq("create_issue")
      expect(new_run.issue).to eq(issue)
      expect(new_run.project).to eq(project)
      expect(new_run.trigger_type).to eq("manual")
      expect(new_run.external_metadata["automatic_authorization"]).to be true
      expect(new_run.agent_type).to eq(agent_run.agent_type)
      expect(new_run.external_metadata[AgentRuns::TimeoutIssueGoalRetryPolicy::OPERATION_KEY]).to eq(
        agent_run.reload.external_metadata[AgentRuns::TimeoutIssueGoalRetryPolicy::OPERATION_KEY]
      )
    end

    it "marks the original run as retried" do
      agent_run = create_timed_out_issue_goal_run

      described_class.perform_now(agent_run.id)

      expect(agent_run.reload.status).to eq("retried")
      event = OrchestrationDecision.last
      expect(event.actor).to eq("timeout_auto_retry")
      expect(event.context["decision_status"]).to eq("applied")
      expect(event.inputs["retry_attempt"]).to eq(1)
      expect(event.outputs["retry_attempt"]).to eq(1)
    end

    it "enqueues ProcessRunQueueJob" do
      agent_run = create_timed_out_issue_goal_run

      expect { described_class.perform_now(agent_run.id) }
        .to have_enqueued_job(ProcessRunQueueJob)
    end

    it "creates at most one replacement when the timeout job is delivered twice" do # @spec AGENT-RETRY-014
      agent_run = create_timed_out_issue_goal_run

      2.times { described_class.perform_now(agent_run.id) }

      expect(AgentRun.where(project: project, issue: issue, goal: "create_issue").count).to eq(2)
      expect(agent_run.reload.status).to eq("retried")
    end

    it "does not retry when max retries reached and sets error_message" do
      described_class::MAX_RETRIES.times do
        create(:agent_run, :timeout, :create_issue_goal,
          project: project, issue: issue, status: "retried")
      end

      agent_run = create_timed_out_issue_goal_run

      allow(Rails.logger).to receive(:info).and_call_original
      expect(Rails.logger).to receive(:info).with(
        message: "agent_execution.issue_goal_retry_limit_reached",
        agent_run_id: agent_run.id,
        issue_id: agent_run.issue_id,
        project_id: agent_run.project_id,
        previous_retries: described_class::MAX_RETRIES,
        max_retries: described_class::MAX_RETRIES
      )

      expect { described_class.perform_now(agent_run.id) }
        .not_to change(AgentRun, :count)

      expect(agent_run.reload.error_message).to eq("Auto-retry limit reached (#{described_class::MAX_RETRIES} retries)")
      event = OrchestrationDecision.last
      expect(event.context["decision_status"]).to eq("noop")
      expect(event.inputs["retry_attempt"]).to eq(described_class::MAX_RETRIES + 1)
    end

    it "does not retry a non-issue-goal run" do
      agent_run = create(:agent_run, :timeout, project: project, issue: issue)

      expect { described_class.perform_now(agent_run.id) }
        .not_to change(AgentRun, :count)
    end

    it "does not retry a run that is not timed out" do
      agent_run = create(:agent_run, :failed, :create_issue_goal,
        project: project, issue: issue)

      expect { described_class.perform_now(agent_run.id) }
        .not_to change(AgentRun, :count)
    end

    it "does nothing if the agent run does not exist" do
      expect { described_class.perform_now(-1) }
        .not_to change(AgentRun, :count)
    end

    it "preserves custom_prompt on retry" do
      agent_run = create_timed_out_issue_goal_run(custom_prompt: "Create an issue about auth")

      described_class.perform_now(agent_run.id)

      new_run = AgentRun.last
      expect(new_run.custom_prompt).to eq("Create an issue about auth")
    end

    it "preserves the initiating user on retry" do
      initiating_user = create(:user, account: project.account)
      agent_run = create_timed_out_issue_goal_run(initiating_user: initiating_user)

      described_class.perform_now(agent_run.id)

      expect(AgentRun.last.initiating_user).to eq(initiating_user)
    end

    it "counts only issue goal runs toward the retry limit" do
      # Create MAX_RETRIES retried PR-goal runs (should not count)
      described_class::MAX_RETRIES.times do
        create(:agent_run, project: project, issue: issue,
          goal: "create_pr", status: "retried")
      end

      agent_run = create_timed_out_issue_goal_run

      expect { described_class.perform_now(agent_run.id) }
        .to change(AgentRun, :count).by(1)
    end

    context "when issue is nil" do
      it "retries a timed-out create_issue run without an issue" do
        agent_run = create(:agent_run, :timeout, :create_issue_goal,
          project: project)

        expect { described_class.perform_now(agent_run.id) }
          .to change(AgentRun, :count).by(1)

        new_run = AgentRun.last
        expect(new_run.status).to eq("queued")
        expect(new_run.goal).to eq("create_issue")
        expect(new_run.issue).to be_nil
        expect(new_run.custom_prompt).to eq(agent_run.custom_prompt)
      end

      it "counts previous attempts by matching goal parameters" do
        base_attrs = {
          project: project, issue: nil, goal: "create_issue",
          custom_prompt: "Create a GitHub issue for the requested task",
          status: "retried"
        }

        described_class::MAX_RETRIES.times do
          legacy_run = create(:agent_run, :create_issue_goal, **base_attrs)
          legacy_run.update_columns(external_metadata: {})
        end

        agent_run = create(:agent_run, :timeout, :create_issue_goal,
          project: project, external_metadata: {})
        agent_run.update_columns(external_metadata: {})

        expect { described_class.perform_now(agent_run.id) }
          .not_to change(AgentRun, :count)
      end

      it "does not charge a new request against equal-prompt legacy retries" do
        legacy_attributes = {
          project: project,
          issue: nil,
          goal: "create_issue",
          custom_prompt: "Create a GitHub issue for the requested task",
          status: "retried",
          external_metadata: {}
        }
        described_class::MAX_RETRIES.times do
          legacy_run = create(:agent_run, :create_issue_goal, **legacy_attributes)
          legacy_run.update_columns(external_metadata: {})
        end
        agent_run = create(:agent_run, :timeout, :create_issue_goal,
          project: project, custom_prompt: legacy_attributes[:custom_prompt])

        expect { described_class.perform_now(agent_run.id) }
          .to change(AgentRun, :count).by(1)
      end

      it "uses the carried operation key for successors instead of prompt text" do
        first_request = create(:agent_run, :timeout, :create_issue_goal,
          project: project, custom_prompt: "Create a GitHub issue for the requested task")
        second_request = create(:agent_run, :timeout, :create_issue_goal,
          project: project, custom_prompt: first_request.custom_prompt)

        described_class.perform_now(first_request.id)
        described_class.perform_now(second_request.id)

        successors = AgentRun.where(status: "queued", project: project).order(:id)
        expect(successors.pluck(Arel.sql("external_metadata ->> '#{AgentRuns::TimeoutIssueGoalRetryPolicy::OPERATION_KEY}'"))).to contain_exactly(
          first_request.external_metadata[AgentRuns::TimeoutIssueGoalRetryPolicy::OPERATION_KEY],
          second_request.external_metadata[AgentRuns::TimeoutIssueGoalRetryPolicy::OPERATION_KEY]
        )
      end

      it "stops after three replacements in one keyed retry chain" do
        agent_run = create(:agent_run, :timeout, :create_issue_goal, project: project)

        described_class::MAX_RETRIES.times do
          described_class.perform_now(agent_run.id)
          agent_run = AgentRun.order(:id).last
          agent_run.update!(status: "timeout")
        end

        expect { described_class.perform_now(agent_run.id) }
          .not_to change(AgentRun, :count)
        expect(agent_run.reload.error_message).to eq("Auto-retry limit reached (#{described_class::MAX_RETRIES} retries)")
      end
    end

    it "skips retry but marks original as retried and enqueues queue processing when an active run already exists" do
      agent_run = create_timed_out_issue_goal_run
      # Create an active (queued) run for the same project+issue to trigger unique index
      existing_run = create(:agent_run, :create_issue_goal, project: project, issue: issue, status: "queued")

      allow(Rails.logger).to receive(:info).and_call_original
      expect(Rails.logger).to receive(:info).with(
        message: "agent_execution.issue_goal_auto_retry_skipped_existing_run",
        original_agent_run_id: agent_run.id,
        existing_agent_run_id: existing_run.id,
        issue_id: issue.id,
        project_id: project.id
      )

      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      described_class.perform_now(agent_run.id)

      process_queue_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.count do |job|
        job[:job] == ProcessRunQueueJob
      end

      expect(process_queue_jobs).to eq(1)
      expect(AgentRun.count).to eq(2) # original + existing active, no new retry
      expect(agent_run.reload.status).to eq("retried")
      expect(OrchestrationDecision.last.outputs["retry_attempt"]).to eq(1)
    end

    it "recovers from an active PR-slot conflict when the issue slot is free" do # @spec AGENT-RETRY-014
      source_pull_request_number = 42
      agent_run = create_timed_out_issue_goal_run(source_pull_request_number: source_pull_request_number)
      existing_run = create(:agent_run, :create_issue_goal, project: project,
        issue: create(:issue, project: project), source_pull_request_number: source_pull_request_number,
        status: "queued")

      expect { described_class.perform_now(agent_run.id) }
        .not_to change(AgentRun, :count)

      expect(agent_run.reload.status).to eq("retried")
      expect(OrchestrationDecision.last.outputs).to include(
        "existing_agent_run_id" => existing_run.id,
        "reason" => "existing_active_run"
      )
      expect(ProcessRunQueueJob).to have_been_enqueued
    end

    it "preserves the original unique-index error when the conflicting run finishes before recovery" do # @spec AGENT-RETRY-014
      agent_run = create_timed_out_issue_goal_run
      error = ActiveRecord::RecordNotUnique.new("PG::UniqueViolation: idx_agent_runs_unique_active_issue")

      expect {
        AgentRuns::TimeoutIssueGoalRetryPolicy.new.handle_duplicate_active_run!(agent_run, 1, error: error)
      }.to raise_error(error)
    end
  end
end
