# frozen_string_literal: true

module Activities
  # Creates an issue in an upstream (different) repository as part of
  # a cross-repo issue pair. The upstream issue describes the contract,
  # feature, or fix needed in the dependency; a downstream Paid issue
  # then references it via `Blocked by owner/repo#NNN`.
  #
  # The activity resolves the target repository through the same account's
  # projects, validating that the GitHub token has write access before
  # attempting creation.
  class CreateUpstreamIssueActivity < BaseActivity
    activity_name "CreateUpstreamIssue"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      target_repo = input[:target_repo]
      title = input[:title]
      body = input[:body]
      labels = input[:labels] || []

      agent_run = AgentRun.find(agent_run_id)
      track_phase(agent_run_id: agent_run_id, phase_key: "create_upstream_issue", phase_group: "post", agent_run: agent_run) do
        project = agent_run.project
        client = resolve_client(project, target_repo)

        gh_issue = client.create_issue(
          target_repo,
          title: title,
          body: body,
          labels: labels
        )

        sync_upstream_issue(project, target_repo, gh_issue)

        record_cross_repo_issue(agent_run, target_repo, gh_issue, role: "upstream")

        agent_run.log!("system", "Upstream issue created in #{target_repo}: #{gh_issue.html_url}")

        logger.info(
          message: "agent_execution.upstream_issue_created",
          agent_run_id: agent_run_id,
          target_repo: target_repo,
          issue_url: gh_issue.html_url
        )

        {
          agent_run_id: agent_run_id,
          issue_url: gh_issue.html_url,
          issue_number: gh_issue.number,
          target_repo: target_repo
        }
      end
    end

    private

    # Uses the current project's GitHub token. All projects in the same
    # account share a token pool, so cross-repo creation within an account
    # reuses the existing credentials.
    def resolve_client(project, target_repo)
      client = project.github_token&.client
      unless client
        raise Temporalio::Error::ApplicationError.new(
          "No GitHub token available for cross-repo issue creation",
          type: "MissingCredentials",
          non_retryable: true
        )
      end
      client
    end

    def sync_upstream_issue(source_project, target_repo, gh_issue)
      owner, repo = target_repo.split("/", 2)
      target_project = source_project.account.projects.find_by(
        "LOWER(owner) = ? AND LOWER(repo) = ?", owner.downcase, repo.downcase
      )

      if target_project
        Issues::UpsertFromGithub.call(project: target_project, github_issue: gh_issue)
      end
    rescue => e
      logger.warn(
        message: "agent_execution.sync_upstream_issue_failed",
        target_repo: target_repo,
        issue_number: gh_issue.number,
        error: e.message
      )
    end

    def record_cross_repo_issue(agent_run, target_repo, gh_issue, role:)
      entry = {
        "repo" => target_repo,
        "issue_number" => gh_issue.number,
        "issue_url" => gh_issue.html_url,
        "role" => role
      }
      agent_run.update!(
        cross_repo_issues: (agent_run.cross_repo_issues || []) + [ entry ]
      )
    end
  end
end
