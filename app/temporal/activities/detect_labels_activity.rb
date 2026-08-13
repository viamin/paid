# frozen_string_literal: true

module Activities
  # Evaluates a synced GitHub record through the shared automation decision
  # layer and returns explicit decisions for the poll workflow to execute.
  class DetectLabelsActivity < BaseActivity
    def execute(input)
      project_id = input[:project_id]
      issue_id = input[:issue_id]
      project = Project.find(project_id)
      issue = project.issues.find(issue_id)
      Automation::IssueEvaluation.call(project:, issue:, logger:)
    rescue GithubClient::RateLimitError => e
      raise Temporalio::Error::ApplicationError.new(
        e.message,
        type: "RateLimit"
      )
    end
  end
end
