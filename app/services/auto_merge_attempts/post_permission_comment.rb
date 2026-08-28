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

    # Match only Paid-authored marker comments when we know the current
    # authenticated login. That prevents third-party comments containing the
    # public marker string from suppressing this blocker notice. `nil` means
    # the identity is unknown (per GithubClient#authenticated_login), not
    # "trust any author" — so treat it the same as a fetch failure and skip
    # posting for this cycle rather than matching marker text from any
    # author. If the login lookup or comment fetch fails, fall back to the
    # safe default and skip posting for this cycle so transient GitHub API
    # errors do not create duplicate comments on every poll.
    #
    # Unlike the HEAD-SHA-scoped marker in RequestReviewActivity (where a
    # stale marker naturally falls out of relevance once HEAD moves), this
    # marker is static for the life of the PR. So the recent-comments window
    # alone isn't enough to guarantee "post exactly once" on long-lived PRs —
    # we walk older pages (mirroring Screenshots::PrComment) until we find the
    # marker or exhaust the comment history.
    def comment_present?(client)
      paid_login = client.authenticated_login
      return true if paid_login.nil?

      comments = client.recent_issue_comments(project.full_name, pr_number)
      marker_comment_in_pages?(client, comments, paid_login)
    rescue GithubClient::Error => e
      logger.warn(
        message: "#{log_component}.merge_permission_comment_check_failed",
        project_id: project.id,
        pr_number: pr_number,
        error_class: e.class.name,
        error_message: e.message.to_s.truncate(200)
      )
      true
    end

    def marker_comment_in_pages?(client, comments, paid_login)
      loop do
        return true if comments.any? { |comment| marker_comment?(comment, paid_login) }
        break unless comments.respond_to?(:next_older_page_url) && comments.next_older_page_url

        comments = client.fetch_issue_comment_page(comments.next_older_page_url)
      end

      false
    end

    def marker_comment?(comment, paid_login)
      return false unless comment.respond_to?(:body) && comment.body&.include?(marker)

      comment.user&.login&.downcase == paid_login
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
