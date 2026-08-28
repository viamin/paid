# frozen_string_literal: true

module AutoMergeAttempts
  # Posts (once) a marker-tagged PR comment explaining that auto-merge is
  # permanently blocked by a missing GitHub App permission. Shared by
  # MergePullRequestActivity and DependabotAutoMergeJob so the marker/dedup
  # logic can't drift between the two auto-merge flows.
  class PostPermissionComment
    def self.call(...)
      new(...).call
    end

    def initialize(project:, pr_number:, marker:, title:, intro:, fallback_attempted:, logger:, log_component:)
      @project = project
      @pr_number = pr_number
      @marker = marker
      @title = title
      @intro = intro
      @fallback_attempted = fallback_attempted
      @logger = logger
      @log_component = log_component
    end

    def call
      client = project.client
      return unless client
      return if comment_present?(client)

      client.add_comment(project.full_name, pr_number, body)
      logger.info(
        message: "#{log_component}.merge_permission_comment_posted",
        project_id: project.id,
        pr_number: pr_number
      )
    rescue GithubClient::Error => e
      logger.warn(
        message: "#{log_component}.merge_permission_comment_failed",
        project_id: project.id,
        pr_number: pr_number,
        error_class: e.class.name,
        error_message: e.message.to_s.truncate(200)
      )
    end

    private

    attr_reader :project, :pr_number, :marker, :title, :intro, :fallback_attempted, :logger, :log_component

    def comment_present?(client)
      comments = client.recent_issue_comments(project.full_name, pr_number)
      comments.any? { |comment| comment.respond_to?(:body) && comment.body&.include?(marker) }
    rescue GithubClient::Error => e
      logger.warn(
        message: "#{log_component}.merge_permission_comment_check_failed",
        project_id: project.id,
        pr_number: pr_number,
        error_class: e.class.name,
        error_message: e.message.to_s.truncate(200)
      )
      false
    end

    def body
      [
        marker,
        title,
        "",
        intro,
        "",
        next_step
      ].join("\n")
    end

    def next_step
      if fallback_attempted
        "**Next step:** the configured PAT push-fallback credential also could not merge this PR — " \
          "check that it has not expired or been revoked, then merge manually or wait for the next automatic check."
      else
        "**Next step:** grant the App the `workflows` permission, or configure a PAT push-fallback " \
          "credential for this project, then merge manually or wait for the next automatic check."
      end
    end
  end
end
