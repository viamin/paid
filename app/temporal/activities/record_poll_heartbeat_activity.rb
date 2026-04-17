# frozen_string_literal: true

module Activities
  # Lightweight activity that records forward progress in a poll workflow
  # by touching `project.last_polled_at`. Called after each major step
  # (fetch issues, detect labels loop, non-critical scans) so the
  # PollWorkflowHealthCheckJob sees the workflow as alive even when a
  # single cycle takes longer than the staleness window.
  #
  # This is intentionally minimal — no return payload beyond confirmation —
  # to keep Temporal history overhead low when called multiple times per cycle.
  class RecordPollHeartbeatActivity < BaseActivity
    def execute(input)
      project = Project.find_by(id: input[:project_id])
      return { recorded: false } unless project

      project.touch_last_polled_at

      { recorded: true }
    end
  end
end
