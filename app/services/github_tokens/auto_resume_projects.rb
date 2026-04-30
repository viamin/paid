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

        resumed_ids << project.id if project.scheduler_resume!
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

    def paused_projects
      @github_token.projects.active.where.not(scheduler_paused_at: nil)
    end
  end
end
