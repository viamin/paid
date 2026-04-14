# frozen_string_literal: true

module Issues
  class UpsertFromGithub
    def self.call(project:, github_issue:, body: github_issue.body)
      issue = project.issues.find_or_initialize_by(github_issue_id: github_issue.id)
      issue.update!(
        github_number: github_issue.number,
        title: github_issue.title,
        body: body,
        github_creator_login: github_issue.user&.login || "unknown",
        github_state: github_issue.state,
        labels: extract_labels(github_issue),
        is_pull_request: github_issue.respond_to?(:pull_request) && github_issue.pull_request.present?,
        github_created_at: github_issue.created_at,
        github_updated_at: github_issue.updated_at
      )
      issue
    end

    def self.extract_labels(github_issue)
      Array(github_issue.labels).map { |label| label.respond_to?(:name) ? label.name : label.to_s }
    end
    private_class_method :extract_labels
  end
end
