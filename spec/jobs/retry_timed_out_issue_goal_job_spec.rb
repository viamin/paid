# frozen_string_literal: true

require "rails_helper"

RSpec.describe RetryTimedOutIssueGoalJob do
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
      expect(new_run.trigger_type).to eq("automatic")
      expect(new_run.agent_type).to eq(agent_run.agent_type)
    end

    it "marks the original run as retried" do
      agent_run = create_timed_out_issue_goal_run

      described_class.perform_now(agent_run.id)

      expect(agent_run.reload.status).to eq("retried")
    end

    it "enqueues ProcessRunQueueJob" do
      agent_run = create_timed_out_issue_goal_run

      expect { described_class.perform_now(agent_run.id) }
        .to have_enqueued_job(ProcessRunQueueJob)
    end

    it "does not retry when max retries reached and sets error_message" do
      # Create MAX_RETRIES previous timed-out runs
      described_class::MAX_RETRIES.times do
        create(:agent_run, :timeout, :create_issue_goal,
          project: project, issue: issue, status: "retried")
      end

      agent_run = create_timed_out_issue_goal_run

      expect { described_class.perform_now(agent_run.id) }
        .not_to change(AgentRun, :count)

      expect(agent_run.reload.error_message).to eq("Auto-retry limit reached (3 attempts)")
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
          create(:agent_run, :create_issue_goal, **base_attrs)
        end

        agent_run = create(:agent_run, :timeout, :create_issue_goal,
          project: project)

        expect { described_class.perform_now(agent_run.id) }
          .not_to change(AgentRun, :count)
      end
    end

    it "skips retry but marks original as retried when an active run already exists" do
      agent_run = create_timed_out_issue_goal_run
      # Create an active (queued) run for the same project+issue to trigger unique index
      create(:agent_run, :create_issue_goal, project: project, issue: issue, status: "queued")

      expect { described_class.perform_now(agent_run.id) }
        .not_to change(AgentRun, :count)

      expect(agent_run.reload.status).to eq("retried")
    end
  end
end
