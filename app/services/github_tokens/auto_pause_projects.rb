# frozen_string_literal: true

module GithubTokens
  class AutoPauseProjects
    AUTO_PAUSE_REASON_PREFIX = "GitHub token '".freeze
    AUTO_PAUSE_REASON_MARKER = "' failed validation:".freeze

    def self.call(...)
      new(...).call
    end

    def self.auto_pause_reason?(reason)
      reason&.start_with?(AUTO_PAUSE_REASON_PREFIX) && reason.include?(AUTO_PAUSE_REASON_MARKER)
    end

    def initialize(github_token:)
      @github_token = github_token
    end

    def call
      # Scoped to .active only (not .where(scheduler_paused_at: nil)) so that
      # projects auto-paused by an earlier run of this service still get
      # stop_polling retried below. scheduler_pause! is idempotent (no-op
      # when already paused), so this call runs safely every time the health
      # check confirms the token is still failing. Manually scheduler-paused
      # projects are left alone here because AutoResumeProjects will not
      # clear their pause reason or restart polling when the token recovers.
      projects = @github_token.projects.active
      paused_ids = []

      projects.find_each do |project|
        was_already_auto_paused = self.class.auto_pause_reason?(project.scheduler_pause_reason)
        was_paused = project.scheduler_pause!(reason: pause_reason)
        paused_ids << project.id if was_paused
        stop_polling(project) if was_paused || was_already_auto_paused
      end

      if paused_ids.any?
        Rails.logger.info(
          message: "github_token.auto_pause",
          github_token_id: @github_token.id,
          project_ids: paused_ids,
          reason: pause_reason
        )
      end

      paused_ids
    end

    private

    # Stops the project's GitHubPollWorkflow so it doesn't keep hitting the
    # known-dead credential every poll cycle indefinitely -- a stopped
    # credential means every subsequent poll attempt is guaranteed to fail
    # identically, so continuing to poll only burns worker capacity and API
    # quota until a human fixes the token. scheduler_pause! (above) already
    # stops new agent runs from being scheduled; this additionally stops the
    # underlying GitHub sync itself. AutoResumeProjects restarts polling
    # when the token becomes valid again.
    def stop_polling(project)
      ProjectWorkflowManager.stop_polling(project)
    rescue => e
      Rails.logger.error(
        message: "github_token.auto_pause.stop_polling_failed",
        github_token_id: @github_token.id,
        project_id: project.id,
        error: e.message
      )
    end

    def pause_reason
      "GitHub token '#{@github_token.name}' failed validation: #{@github_token.validation_error}"
    end
  end
end
