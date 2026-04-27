# frozen_string_literal: true

module GithubTokens
  class AutoPauseProjects
    def self.call(...)
      new(...).call
    end

    def initialize(github_token:)
      @github_token = github_token
    end

    def call
      projects = @github_token.projects.active.where(scheduler_paused_at: nil)
      paused_ids = []

      projects.find_each do |project|
        paused_ids << project.id if project.scheduler_pause!(reason: pause_reason)
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

    def pause_reason
      "GitHub token '#{@github_token.name}' failed validation: #{@github_token.validation_error}"
    end
  end
end
