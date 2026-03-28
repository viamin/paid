# frozen_string_literal: true

module Activities
  # Handles issue-based agent runs that complete without producing a PR or commit.
  #
  # Classifies the outcome as either:
  # - `recommend_close`: agent produced output but no code changes (issue may be
  #   already satisfied, obsolete, or not actionable)
  # - `needs_input`: agent produced no output and no changes (issue is likely
  #   underspecified or ambiguous)
  #
  # For each outcome, posts a GitHub comment with actionable next steps and
  # updates the Paid-side issue state so users are not left at a dead end.
  class HandleNoOutputIssueRunActivity < BaseActivity
    activity_name "HandleNoOutputIssueRun"

    PAID_NEEDS_INPUT_LABEL = "paid-needs-input"
    NEEDS_INPUT_COMMENT_MARKER = "<!-- paid:needs-input -->"
    RECOMMEND_CLOSE_COMMENT_MARKER = "<!-- paid:recommend-close -->"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      output_present = input.fetch(:output_present, false)

      agent_run = AgentRun.find(agent_run_id)
      issue = agent_run.issue

      unless issue
        return track_phase(agent_run_id: agent_run_id, phase_key: "handle_no_output_issue_run", phase_group: "post", agent_run: agent_run, metadata: { outcome: "no_issue" }) do
          mark_complete_without_issue(agent_run)
        end
      end

      project = agent_run.project
      client = project.github_token.client
      outcome = output_present ? "recommend_close" : "needs_input"

      track_phase(agent_run_id: agent_run_id, phase_key: "handle_no_output_issue_run", phase_group: "post", agent_run: agent_run, metadata: { outcome: outcome }) do
        agent_summary = agent_run.agent_summary_with_stderr_fallback(limit: 100)

        if outcome == "needs_input"
          handle_needs_input(client, agent_run, agent_summary)
        else
          handle_recommend_close(client, agent_run, agent_summary)
        end

        agent_run.complete!
        agent_run.log!("system", "Completed without PR: #{outcome}")

        logger.info(
          message: "agent_execution.no_output_issue_run",
          agent_run_id: agent_run_id,
          outcome: outcome,
          issue_id: issue.id
        )

        ProcessRunQueueJob.perform_later

        { agent_run_id: agent_run_id, outcome: outcome }
      end
    end

    private

    def handle_needs_input(client, agent_run, agent_summary)
      project = agent_run.project
      issue = agent_run.issue
      issue.update!(paid_state: "needs_input")
      add_needs_input_label(client, project, issue)
      remove_trigger_labels(client, project, issue, agent_run.id)
      post_needs_input_comment(client, project, issue, agent_summary)
    end

    def handle_recommend_close(client, agent_run, agent_summary)
      project = agent_run.project
      issue = agent_run.issue
      issue.update!(paid_state: "recommend_close")
      remove_trigger_labels(client, project, issue, agent_run.id)
      remove_needs_input_label(client, project, issue, agent_run.id)
      post_recommend_close_comment(client, project, issue, agent_summary)
    end

    def mark_complete_without_issue(agent_run)
      agent_run.complete!
      agent_run.log!("system", "Completed without PR: no_changes")
      ProcessRunQueueJob.perform_later
      { agent_run_id: agent_run.id, outcome: "no_changes" }
    end

    def triggering_label_for(project)
      if project.automation_on_label_enabled? && project.automation_label_name.present?
        project.automation_label_name
      else
        project.label_for_stage("build") || "paid-build"
      end
    end

    def add_needs_input_label(client, project, issue)
      label = project.label_for_stage("needs_input") || PAID_NEEDS_INPUT_LABEL
      add_phase_label(client, project, issue.github_number, label)
    end

    def remove_needs_input_label(client, project, issue, agent_run_id)
      label = project.label_for_stage("needs_input") || PAID_NEEDS_INPUT_LABEL
      return unless issue.has_label?(label)

      client.remove_label_from_issue(project.full_name, issue.github_number, label)
    rescue GithubClient::Error => e
      logger.warn(
        message: "agent_execution.remove_needs_input_label_failed",
        agent_run_id: agent_run_id,
        issue_number: issue.github_number,
        label: label,
        error: e.message
      )
    end

    def remove_trigger_labels(client, project, issue, agent_run_id)
      %w[build plan].each do |stage|
        label = project.label_for_stage(stage)
        next unless label && issue.has_label?(label)

        begin
          client.remove_label_from_issue(project.full_name, issue.github_number, label)
        rescue GithubClient::Error => e
          logger.warn(
            message: "agent_execution.remove_trigger_label_failed",
            agent_run_id: agent_run_id,
            issue_number: issue.github_number,
            label: label,
            error: e.message
          )
        end
      end
    end

    def post_needs_input_comment(client, project, issue, agent_summary)
      return if comment_exists?(client, project, issue, NEEDS_INPUT_COMMENT_MARKER)

      automation_label = triggering_label_for(project)
      needs_input_label = project.label_for_stage("needs_input") || PAID_NEEDS_INPUT_LABEL

      lines = [
        NEEDS_INPUT_COMMENT_MARKER,
        "**Needs Input**",
        "",
        "The agent was unable to proceed and did not create a pull request.",
        ""
      ]

      if agent_summary.present?
        lines.concat([
          "**Agent output:**",
          "",
          agent_summary.truncate(2000),
          ""
        ])
      end

      lines.concat([
        "**Next steps:**",
        "1. A trusted collaborator should reply to this issue with clarifying details.",
        "2. Remove the `#{needs_input_label}` label.",
        "3. Add the `#{automation_label}` label to trigger another run.",
        ""
      ])

      client.add_comment(project.full_name, issue.github_number, lines.join("\n"))
    rescue GithubClient::Error => e
      logger.warn(
        message: "agent_execution.needs_input_comment_failed",
        issue_number: issue.github_number,
        error: e.message
      )
    end

    def post_recommend_close_comment(client, project, issue, agent_summary)
      return if comment_exists?(client, project, issue, RECOMMEND_CLOSE_COMMENT_MARKER)

      lines = [
        RECOMMEND_CLOSE_COMMENT_MARKER,
        "**Recommend Close**",
        "",
        "The agent completed but did not create a pull request. " \
          "This issue may already be resolved, obsolete, or not actionable.",
        ""
      ]

      if agent_summary.present?
        lines.concat([
          "**Agent output:**",
          "",
          agent_summary.truncate(2000),
          ""
        ])
      end

      lines.concat([
        "**Next steps:**",
        "- If this issue is resolved, close it.",
        "- If more work is needed, add clarifying details and re-trigger the automation.",
        ""
      ])

      client.add_comment(project.full_name, issue.github_number, lines.join("\n"))
    rescue GithubClient::Error => e
      logger.warn(
        message: "agent_execution.recommend_close_comment_failed",
        issue_number: issue.github_number,
        error: e.message
      )
    end

    def comment_exists?(client, project, issue, marker)
      comments = client.recent_issue_comments(project.full_name, issue.github_number)
      comments.any? { |c| c.respond_to?(:body) && c.body&.include?(marker) }
    rescue GithubClient::Error => e
      logger.warn(
        message: "agent_execution.fetch_comments_failed",
        issue_number: issue.github_number,
        error: e.message
      )
      false
    end
  end
end
