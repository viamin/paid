# frozen_string_literal: true

module Activities
  class CaptureScreenshotsActivity < BaseActivity
    activity_name "CaptureScreenshots"

    def execute(input)
      agent_run = AgentRun.find(input[:agent_run_id])

      # Upstream mode (#4078): no screenshot capture or PR comment on PRs
      # opened in the upstream repository. Screenshots::ContainerCapture
      # independently refuses (project.screenshots_enabled? is gated on the
      # model), so this early return is the explainable first gate.
      # @spec UPSTREAM-GATE-002
      unless agent_run.project.upstream_feature_enabled?(:screenshots)
        return {
          agent_run_id: agent_run.id,
          status: "upstream_mode_skipped",
          screenshot_count: 0,
          artifacts: [],
          screenshots_url: nil,
          error: nil
        }
      end

      track_phase(
        agent_run_id: agent_run.id,
        phase_key: "capture_screenshots",
        phase_group: "post",
        agent_run: agent_run
      ) do
        result = with_periodic_heartbeat("capture_screenshots", agent_run_id: agent_run.id) do
          Screenshots::ContainerCapture.call(agent_run: agent_run, logger: logger)
        end

        logger.info(
          message: "screenshots.capture_activity_completed",
          agent_run_id: agent_run.id,
          status: result.status,
          screenshot_count: result.screenshot_paths.size,
          artifact_count: result.artifacts.size
        )

        {
          agent_run_id: agent_run.id,
          status: result.status,
          screenshot_count: result.screenshot_paths.size,
          artifacts: result.artifacts,
          screenshots_url: result.screenshots_url,
          error: result.error
        }
      end
    end
  end
end
