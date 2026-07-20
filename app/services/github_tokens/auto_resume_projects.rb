# frozen_string_literal: true

module GithubTokens
  class AutoResumeProjects
    def self.call(...)
      new(...).call
    end

    def initialize(github_token:)
      @github_token = github_token
    end

    def call
      resumed_ids = []

      paused_projects.find_each do |project|
        next unless GithubTokens::AutoPauseProjects.auto_pause_reason?(project.scheduler_pause_reason)
        next unless resume_project(project)

        resumed_ids << project.id
      end

      if resumed_ids.any?
        Rails.logger.info(
          message: "github_token.auto_resume",
          github_token_id: @github_token.id,
          project_ids: resumed_ids
        )
      end

      resumed_ids
    end

    private

    def resume_project(project)
      return project.scheduler_resume! unless project.active?
      return false unless start_polling(project)

      project.scheduler_resume!
    end

    # Restarts the project's GitHubPollWorkflow, undoing AutoPauseProjects'
    # stop_polling now that the credential is valid again.
    def start_polling(project)
      ProjectWorkflowManager.start_polling(project, restart_reason: "github_token_restored")
      true
    rescue => e
      Rails.logger.error(
        message: "github_token.auto_resume.start_polling_failed",
        github_token_id: @github_token.id,
        project_id: project.id,
        error: e.message
      )
      false
    end

    def paused_projects
      @github_token.projects.where.not(scheduler_paused_at: nil)
    end
  end
end
