# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRun, type: :model do
  include ActiveJob::TestHelper

  describe "resource profile refresh enqueue" do
    it "enqueues a profile refresh when a run finishes" do
      agent_run = create(:agent_run, :running, agent_type: "claude_code", final_runner: "claude")

      expect {
        agent_run.complete!
      }.to have_enqueued_job(AgentRunResourceProfileRefreshJob).with(agent_run.id)
    end

    it "detects OOM evidence from the run error or attempted runners" do
      agent_run = create(:agent_run,
        :failed,
        error_message: "Command failed (container OOM-killed; memory limit 4.0 GB)")
      expect(agent_run.resource_profile_oom?).to be(true)

      agent_run.update_columns(
        error_message: "plain failure",
        runners_attempted: [
          { "runner" => "claude", "error_message" => "retry later (container OOM-killed)" }
        ]
      )

      expect(agent_run.resource_profile_oom?).to be(true)
    end

    it "detects docker exec SIGKILL OOM evidence from the run error" do
      agent_run = create(:agent_run,
        :failed,
        error_message: "Agent exited with code 137 (process killed by SIGKILL; container OOM not reported; configured memory limit 0.6 GB, container_running=false)")

      expect(agent_run.resource_profile_oom?).to be(true)
    end

    it "ignores docker exec SIGKILL attempts when the container is still running" do
      agent_run = create(:agent_run,
        :failed,
        error_message: "plain failure",
        runners_attempted: [
          {
            "runner" => "claude",
            "error_message" => "Preflight check failed: Agent exited with code 137 (process killed by SIGKILL; container OOM not reported; configured memory limit 0.6 GB, container_running=true)"
          }
        ])

      expect(agent_run.resource_profile_oom?).to be(false)
    end
  end
end
