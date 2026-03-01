# frozen_string_literal: true

module Activities
  # Retrieves the configured poll interval for a project and records a
  # heartbeat by updating `last_polled_at`. This runs at the end of each
  # poll cycle, so the timestamp serves as a reliable indicator that the
  # full cycle completed (used by PollWorkflowHealthCheckJob to detect
  # stale RUNNING workflows).
  #
  # Extracted as an activity because workflows cannot perform I/O directly.
  class GetPollIntervalActivity < BaseActivity
    def execute(input)
      project_id = input[:project_id]
      project = Project.find_by(id: project_id)
      return { poll_interval_seconds: 0, project_missing: true } unless project

      project.touch_last_polled_at

      { poll_interval_seconds: project.poll_interval_seconds }
    end
  end
end
