# frozen_string_literal: true

module Activities
  # Handles issue-based agent runs that complete without producing a PR or commit.
  #
  # Classifies the outcome as either:
  # - `recommend_close`: agent produced output but no code changes (issue may be
  #   already satisfied, obsolete, or not actionable)
  # - `needs_input`: agent produced no output and no changes (issue is likely
  #   underspecified or ambiguous)
  # - `provider_error`: provider returned an error (e.g. credit/quota exhaustion)
  #   before the agent actually ran. The run is failed so retry / provider
  #   fallback handles it instead of parking the issue.
  #
  # For each outcome (other than `provider_error`), posts a GitHub comment with
  # actionable next steps and updates the Paid-side issue state so users are not
  # left at a dead end.
  class HandleNoOutputIssueRunActivity < BaseActivity
    activity_name "HandleNoOutputIssueRun"

    PAID_NEEDS_INPUT_LABEL = "paid-needs-input"
    NEEDS_INPUT_COMMENT_MARKER = "<!-- paid:needs-input -->"
    RECOMMEND_CLOSE_COMMENT_MARKER = "<!-- paid:recommend-close -->"

    SUPPLEMENTARY_ERROR_PATTERNS = [
      /quota exceeded/i,
      /rate.?limit/i,
      /too many requests/i,
      /\b429\b/,
      /add more credits/i,
      /not enough credits/i,
      /purchase (?:more )?credits/i,
      /buy (?:more )?credits/i,
      /requires? more credits/i
    ].freeze

    INFRASTRUCTURE_ERROR_PATTERNS = [
      /bwrap:.*namespace/i,
      /no permissions to create a new namespace/i,
      /non-privileged user namespaces/i,
      /cannot create namespace/i,
      /unshare failed/i,
      /bubblewrap.*(error|fail)/i,
      /container.*failed to start/i,
      /failed to create container/i,
      /sandbox.*error/i,
      /docker.*permission denied/i,
      /exec format error/i
    ].freeze

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
      agent_summary = agent_run.agent_summary_with_stderr_fallback(limit: 100)
      outcome = classify_outcome(agent_run, output_present, agent_summary)

      track_phase(agent_run_id: agent_run_id, phase_key: "handle_no_output_issue_run", phase_group: "post", agent_run: agent_run, metadata: { outcome: outcome }) do
        case outcome
        when "provider_error"
          handle_provider_error(agent_run, agent_summary)
        when "infrastructure_error"
          handle_infrastructure_error(agent_run, agent_summary)
        when "needs_input"
          handle_needs_input(client, agent_run, agent_summary)
          agent_run.complete!
          agent_run.log!("system", "Completed without PR: #{outcome}")
        else
          handle_recommend_close(client, agent_run, agent_summary)
          agent_run.complete!
          agent_run.log!("system", "Completed without PR: #{outcome}")
        end

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

    # Determines the correct outcome for this run based on output presence
    # and evidence that the agent actually performed work. Defense in depth:
    # even if RunAgentActivity failed to detect a provider error, this check
    # prevents credit/quota errors from being misclassified as recommend_close.
    def classify_outcome(agent_run, output_present, agent_summary)
      return "needs_input" unless output_present

      # Guard: if the agent produced output but shows no evidence of having
      # actually run (zero iterations AND zero cost), the "output" is likely
      # a provider-level error (e.g. credit exhaustion) rather than a real
      # agent response. Confirm by checking the output for error patterns.
      if agent_run.iterations.to_i.zero? && agent_run.cost_cents.to_i.zero?
        return "provider_error" if provider_error_output?(agent_summary)
        return "infrastructure_error" if infrastructure_error_output?(agent_summary)
      end

      "recommend_close"
    end

    def provider_error_output?(text)
      return false if text.blank?

      provider_error_patterns.any? { |pattern| text.match?(pattern) }
    end

    def infrastructure_error_output?(text)
      return false if text.blank?

      INFRASTRUCTURE_ERROR_PATTERNS.any? { |pattern| text.match?(pattern) }
    end

    def provider_error_patterns
      @provider_error_patterns ||= RunnerSupport.aggregated_error_classification_patterns(:quota) +
        SUPPLEMENTARY_ERROR_PATTERNS
    end

    def handle_provider_error(agent_run, agent_summary)
      agent_run.fail!(error: "Provider error detected in output: #{agent_summary.to_s.truncate(500)}")
      agent_run.log!("system", "Failed: provider error detected in output (not a real agent response)")
      transition_issue_to_failed(agent_run)
    end

    def handle_infrastructure_error(agent_run, agent_summary)
      agent_run.fail!(error: "Infrastructure error detected in output: #{agent_summary.to_s.truncate(500)}")
      agent_run.log!("system", "Failed: infrastructure error detected in output (container/sandbox failure)")
      transition_issue_to_failed(agent_run)
    end

    # Transitions the issue to "failed" so it doesn't stay stuck in
    # "in_progress". This mirrors MarkAgentRunFailedActivity's issue
    # state handling — necessary here because this activity runs on
    # the success path, so MarkAgentRunFailedActivity won't execute.
    def transition_issue_to_failed(agent_run)
      issue = agent_run.issue
      return unless issue

      issue.update!(paid_state: "failed") if issue.paid_state != "failed"
    end

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
        project.label_for_stage("build")
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
      labels_to_remove = %w[build plan].filter_map { |stage| project.label_for_stage(stage) }

      if project.automation_on_label_enabled? && project.automation_label_name.present?
        labels_to_remove << project.automation_label_name
      end

      present_labels = labels_to_remove.uniq.select { |label| issue.has_label?(label) }
      return if present_labels.empty?

      result = client.remove_labels_from_issue(project.full_name, issue.github_number, present_labels)
      result[:failed].each do |failure|
        logger.warn(
          message: "agent_execution.remove_trigger_label_failed",
          agent_run_id: agent_run_id,
          issue_number: issue.github_number,
          label: failure[:label],
          error: failure[:error]
        )
      end
    end

    # Redacts lines that match known provider-error patterns so raw
    # provider error text (e.g. OpenRouter billing URLs, credit balances)
    # is never posted to public GitHub comments.
    def sanitize_summary_for_github(text)
      return text if text.blank?

      text.each_line.reject { |line| provider_error_output?(line) }.join.strip
    end

    def post_needs_input_comment(client, project, issue, agent_summary)
      return if comment_exists?(client, project, issue, NEEDS_INPUT_COMMENT_MARKER)

      automation_label = triggering_label_for(project)
      needs_input_label = project.label_for_stage("needs_input") || PAID_NEEDS_INPUT_LABEL
      sanitized_summary = sanitize_summary_for_github(agent_summary)

      lines = [
        NEEDS_INPUT_COMMENT_MARKER,
        "**Needs Input**",
        "",
        "The agent was unable to proceed and did not create a pull request.",
        ""
      ]

      if sanitized_summary.present?
        lines.concat([
          "**Agent output:**",
          "",
          sanitized_summary.truncate(2000),
          ""
        ])
      end

      next_steps = [
        "**Next steps:**",
        "1. A trusted collaborator should reply to this issue with clarifying details.",
        "2. Remove the `#{needs_input_label}` label."
      ]

      if automation_label
        next_steps << "3. Add the `#{automation_label}` label to trigger another run."
      else
        next_steps << "3. Re-trigger the automation to start another run."
      end

      next_steps << ""
      lines.concat(next_steps)

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

      automation_label = triggering_label_for(project)
      sanitized_summary = sanitize_summary_for_github(agent_summary)

      lines = [
        RECOMMEND_CLOSE_COMMENT_MARKER,
        "**Recommend Close**",
        "",
        "The agent completed but did not create a pull request. " \
          "This issue may already be resolved, obsolete, or not actionable.",
        ""
      ]

      if sanitized_summary.present?
        lines.concat([
          "**Agent output:**",
          "",
          sanitized_summary.truncate(2000),
          ""
        ])
      end

      retrigger_instruction = if automation_label
        "add clarifying details and add the `#{automation_label}` label to trigger another run."
      else
        "add clarifying details and re-trigger the automation."
      end

      lines.concat([
        "**Next steps:**",
        "- If this issue is resolved, close it.",
        "- If more work is needed, #{retrigger_instruction}",
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
