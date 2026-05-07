# frozen_string_literal: true

module Activities
  class CaptureScreenshotsActivity < BaseActivity
    activity_name "CaptureScreenshots"

    def execute(input)
      agent_run = AgentRun.find(input[:agent_run_id])

      track_phase(
        agent_run_id: agent_run.id,
        phase_key: "capture_screenshots",
        phase_group: "post",
        agent_run: agent_run
      ) do
        result = Screenshots::ContainerCapture.call(agent_run: agent_run, logger: logger)

        logger.info(
          message: "screenshots.capture_activity_completed",
          agent_run_id: agent_run.id,
          status: result.status,
          screenshot_count: result.screenshot_paths.size
        )

        {
          agent_run_id: agent_run.id,
          status: result.status,
          screenshot_count: result.screenshot_paths.size,
          screenshots_url: result.screenshots_url,
          error: result.error
        }
      end
    end
  end
end
