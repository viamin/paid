# frozen_string_literal: true

module Activities
  # Handles issue-based agent runs that complete without producing a PR or commit.
  #
  # Classifies the outcome as either:
  # - `no_code_required`: the agent explicitly declared (via a marker in its
  #   output) that the issue's work is complete and no code change is needed
  #   — e.g. an umbrella/verification issue whose closeout scope is docs and
  #   follow-up filing. Distinct from `recommend_close` because it is an
  #   agent-asserted completion, not a Paid-side guess.
  # - `recommend_close`: agent performed real work (iterations/cost > 0) but
  #   produced no code changes (issue may be already satisfied, obsolete, or
  #   not actionable)
  # - `needs_input`: reserved for future classifications where there are
  #   concrete questions for a human to answer
  # - `provider_error`: provider returned an error (e.g. credit/quota exhaustion)
  #   before the agent actually ran. The run is failed so retry / provider
  #   fallback handles it instead of parking the issue.
  #
  # For each human-actionable outcome, posts a GitHub comment with
  # actionable next steps and updates the Paid-side issue state so users are not
  # left at a dead end.
  class HandleNoOutputIssueRunActivity < BaseActivity
    activity_name "HandleNoOutputIssueRun"

    CLASSIFICATION_LOG_LIMIT = 500
    PAID_NEEDS_INPUT_LABEL = "paid-needs-input"
    PAID_RECOMMEND_CLOSE_LABEL = "paid-recommend-close"
    NEEDS_INPUT_COMMENT_MARKER = "<!-- paid:needs-input -->"
    RECOMMEND_CLOSE_COMMENT_MARKER = "<!-- paid:recommend-close -->"
    NO_CODE_REQUIRED_COMMENT_MARKER = "<!-- paid:no-code-required-complete -->"
    ISSUE_EXPLANATION_COMMENT_FAILURE_KEY = "issue_explanation_comment_failure"

    # Agent-emitted declaration channel (parsed from the agent's own output,
    # never posted to GitHub verbatim). Mirrors the fenced-block
    # marker pattern used by ParseCrossRepoIssuePlanActivity.
    NO_CODE_REQUIRED_DECLARATION_PATTERN = /<!--\s*paid:no-code-required\s*-->/.freeze
    NO_CODE_REQUIRED_RATIONALE_PATTERN = /<!--\s*no-code-required-rationale-start\s*-->\n?(.*?)\n?<!--\s*no-code-required-rationale-end\s*-->/m.freeze

    SUPPLEMENTARY_ERROR_PATTERNS = [
      /quota exceeded/i,
      /rate.?limit/i,
      /too many requests/i,
      /\b429\b/,
      /free model usage limit reached/i,
      /requires more credits,? or fewer max_tokens/i,
      /can only afford \d+/i,
      %r{visit .*/credits .*add more credits}i,
      /add more credits/i,
      /not enough credits/i,
      /purchase (?:more )?credits/i,
      /buy (?:more )?credits/i,
      /requires? more credits/i
    ].freeze

    COMMENT_REDACTION_ONLY_PATTERNS = [
      /requires more credits/i,
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
      /exec format error/i,
      # Agent CLI misconfiguration: the agent process started but its
      # configured model is not resolvable (e.g. opencode's
      # ProviderModelNotFoundError when the configured provider/model
      # pair is missing). The agent does no work, so this must not be
      # misclassified as recommend_close. The trailing colon in the
      # `Model not found:` pattern matches opencode's actual output
      # (`Error: Model not found: glm-5.1/.`) and avoids false-positives
      # on agents that simply quote that phrase from an issue body.
      /ProviderModelNotFoundError/,
      /Model not found:/i
    ].freeze

    TERMINAL_INFRASTRUCTURE_ERROR_PATTERNS = [
      /no space left on device/i,
      /permission requested: .*auto-rejecting/i
    ].freeze
    PERMISSION_REQUESTED_PATTERN = /permission requested:/i
    TOOL_PERMISSION_REJECTED_PATTERN = /the user rejected permission to use this specific tool call/i

    def execute(input) # @spec NO-OUTPUT-ISSUE-001 NO-OUTPUT-ISSUE-002 NO-OUTPUT-ISSUE-003 NO-OUTPUT-ISSUE-004 NO-OUTPUT-ISSUE-005
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
      client = project.client
      # Small window: quoted back to humans in the GitHub comment only.
      # Classification reads wider windows (see classification_text_for and
      # declaration_text_for) so it never turns on where output landed.
      agent_summary = agent_run.agent_summary_with_stderr_fallback(limit: 100)
      diagnostic_output = classification_text_for(agent_run)
      no_code_required_rationale = parse_no_code_required_rationale(declaration_text_for(agent_run))
      outcome = classify_outcome(agent_run, output_present, diagnostic_output, no_code_required_rationale)

      track_phase(agent_run_id: agent_run_id, phase_key: "handle_no_output_issue_run", phase_group: "post", agent_run: agent_run, metadata: { outcome: outcome }) do
        case outcome
        when "provider_error"
          handle_provider_error(client, agent_run, agent_summary)
        when "infrastructure_error"
          handle_infrastructure_error(client, agent_run, agent_summary)
        when "no_code_required"
          handle_no_code_required(client, agent_run, no_code_required_rationale)
          agent_run.complete!
          agent_run.log!("system", "Completed without PR: #{outcome}")
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
    def classify_outcome(agent_run, output_present, diagnostic_output, no_code_required_rationale)
      return "infrastructure_error" if terminal_infrastructure_error_output?(diagnostic_output)

      unless output_present
        return "provider_error" if provider_error_output?(diagnostic_output)
        return "infrastructure_error" if infrastructure_error_output?(diagnostic_output)

        return "infrastructure_error"
      end

      # Guard: if the agent produced output but did zero iterations, the
      # "output" is likely a provider-level error, trivial CLI boilerplate,
      # or an agent that read the prompt then gave up without doing real
      # work. Cost-cents alone is not evidence of work — reading the
      # prompt incurs a few cents. Recommend-close requires real iterations
      # so users are not left with issues parked on transient agent failures.
      # Confirm provider/infrastructure errors against output patterns first.
      if agent_run.iterations.to_i.zero?
        return "provider_error" if provider_error_output?(diagnostic_output)
        return "infrastructure_error" if infrastructure_error_output?(diagnostic_output)

        return "infrastructure_error"
      end

      return "no_code_required" if no_code_required_rationale.present?

      "recommend_close"
    end

    # Parses the agent's declared no-code-required rationale from the
    # classification output window. Returns nil unless both the declaration
    # marker and a non-blank rationale block are present, so a malformed
    # declaration (marker with no rationale) falls through to the existing
    # classification heuristics instead of silently completing the issue with
    # no human-visible reason.
    def parse_no_code_required_rationale(summary)
      return nil if summary.blank?
      return nil unless summary.match?(NO_CODE_REQUIRED_DECLARATION_PATTERN)

      summary[NO_CODE_REQUIRED_RATIONALE_PATTERN, 1]&.strip.presence
    end

    def provider_error_output?(text)
      return false if text.blank?

      normalized_text(text).each_line.any? { |line| provider_error_signal_line?(line) }
    end

    def provider_error_redaction_line?(text)
      return false if text.blank?

      provider_error_redaction_patterns.any? { |pattern| text.match?(pattern) }
    end

    def infrastructure_error_output?(text)
      return false if text.blank?

      INFRASTRUCTURE_ERROR_PATTERNS.any? { |pattern| text.match?(pattern) }
    end

    def terminal_infrastructure_error_output?(text)
      return false if text.blank?

      TERMINAL_INFRASTRUCTURE_ERROR_PATTERNS.any? { |pattern| text.match?(pattern) } ||
        auto_rejected_tool_permission_output?(text)
    end

    def auto_rejected_tool_permission_output?(text)
      text.match?(TOOL_PERMISSION_REJECTED_PATTERN) &&
        text.match?(PERMISSION_REQUESTED_PATTERN)
    end

    def classification_text_for(agent_run)
      normalized_text(recent_log_content(agent_run, %w[stdout stderr]))
    end

    # @spec NO-OUTPUT-ISSUE-005
    # Output window used for classification, as opposed to the smaller excerpt
    # quoted back in the GitHub comment. Agents emit the no-code-required
    # declaration at the end of a run, so parsing it from the comment excerpt
    # would let a verbose run push the declaration out of the window and be
    # silently misclassified as recommend_close.
    #
    # Combines stdout and stderr rather than falling back to stderr only when
    # stdout is blank: agent_summary_with_stderr_fallback treats stderr as a
    # legitimate output channel for issue runs, so a mixed-output run (normal
    # progress on stdout, the no-code-required block on stderr) must still be
    # searched on both streams or the declaration is missed.
    def declaration_text_for(agent_run)
      stdout = agent_run.normalized_agent_output(recent_log_content(agent_run, %w[stdout]))
      stderr = recent_log_content(agent_run, %w[stderr])

      [ stdout, stderr ].select(&:present?).join("\n")
    end

    # Most recent CLASSIFICATION_LOG_LIMIT entries, restored to chronological
    # order so multi-line agent output reads the way the agent emitted it.
    def recent_log_content(agent_run, log_types)
      agent_run.agent_run_logs
        .where(log_type: log_types)
        .order(created_at: :desc, id: :desc)
        .limit(CLASSIFICATION_LOG_LIMIT)
        .pluck(:content)
        .reverse
        .join("\n")
        .strip
    end

    def provider_error_classification_patterns
      @provider_error_classification_patterns ||= begin
        combined = RunnerSupport.aggregated_error_classification_patterns(:quota) + SUPPLEMENTARY_ERROR_PATTERNS
        combined.reject { |pattern| redaction_only_pattern?(pattern) }.uniq
      end
    end

    def provider_error_upstream_patterns
      @provider_error_upstream_patterns ||= RunnerSupport.aggregated_error_classification_patterns(:quota)
    end

    def provider_error_redaction_patterns
      @provider_error_redaction_patterns ||= RunnerSupport.aggregated_error_classification_patterns(:quota) +
        SUPPLEMENTARY_ERROR_PATTERNS
    end

    def provider_error_signal_line?(line)
      normalized_line = normalized_text(line)
      return false if normalized_line.blank?

      return true if provider_error_classification_patterns.any? { |pattern| normalized_line.match?(pattern) }

      provider_error_upstream_patterns.any? { |pattern| normalized_line.match?(pattern) } &&
        !provider_error_redaction_line?(normalized_line)
    end

    def redaction_only_pattern?(pattern)
      COMMENT_REDACTION_ONLY_PATTERNS.any? do |redaction_pattern|
        pattern.source == redaction_pattern.source && pattern.options == redaction_pattern.options
      end
    end

    def normalized_text(text)
      text.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "\uFFFD").strip
    end

    def handle_provider_error(client, agent_run, agent_summary)
      agent_run.fail!(error: "Provider error detected in output: #{agent_summary.to_s.truncate(500)}")
      agent_run.log!("system", "Failed: provider error detected in output (not a real agent response)")
      transition_issue_to_failed(agent_run)
      remove_trigger_labels(client, agent_run.project, agent_run.issue, agent_run.id)
    end

    def handle_infrastructure_error(client, agent_run, agent_summary)
      agent_run.fail!(error: "Infrastructure error detected in output: #{agent_summary.to_s.truncate(500)}")
      agent_run.log!("system", "Failed: infrastructure error detected in output (container/sandbox failure)")
      transition_issue_to_failed(agent_run)
      remove_trigger_labels(client, agent_run.project, agent_run.issue, agent_run.id)
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
      remove_recommend_close_label(client, project, issue, agent_run.id)
      remove_trigger_labels(client, project, issue, agent_run.id)
      post_needs_input_comment(client, agent_run, agent_summary)
    end

    # The agent explicitly declared this issue's work complete without a code
    # change (e.g. an umbrella/verification issue whose closeout scope is
    # docs/follow-ups). Distinct from recommend_close: this is an
    # agent-asserted completion, so the issue is marked `completed` (the same
    # paid_state used elsewhere for no-PR runs that finished the requested
    # work) rather than parked for human triage.
    def handle_no_code_required(client, agent_run, rationale)
      project = agent_run.project
      issue = agent_run.issue
      issue.update!(paid_state: "completed")
      remove_trigger_labels(client, project, issue, agent_run.id)
      remove_needs_input_label(client, project, issue, agent_run.id)
      remove_recommend_close_label(client, project, issue, agent_run.id)
      post_no_code_required_comment(client, agent_run, rationale)
    end

    def handle_recommend_close(client, agent_run, agent_summary)
      project = agent_run.project
      issue = agent_run.issue
      issue.update!(paid_state: "recommend_close")
      remove_trigger_labels(client, project, issue, agent_run.id)
      remove_needs_input_label(client, project, issue, agent_run.id)
      add_recommend_close_label(client, project, issue)
      post_recommend_close_comment(client, agent_run, agent_summary)
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

    def add_recommend_close_label(client, project, issue)
      label = project.label_for_stage("recommend_close") || PAID_RECOMMEND_CLOSE_LABEL
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

    def remove_recommend_close_label(client, project, issue, agent_run_id)
      label = project.label_for_stage("recommend_close") || PAID_RECOMMEND_CLOSE_LABEL
      return unless issue.has_label?(label)

      client.remove_label_from_issue(project.full_name, issue.github_number, label)
    rescue GithubClient::Error => e
      logger.warn(
        message: "agent_execution.remove_recommend_close_label_failed",
        agent_run_id: agent_run_id,
        issue_number: issue.github_number,
        label: label,
        error: e.message
      )
    end

    def remove_trigger_labels(client, project, issue, agent_run_id)
      return unless issue

      labels_to_remove = %w[build plan].filter_map { |stage| project.label_for_stage(stage) }

      if project.automation_on_label_enabled? && project.automation_label_name.present?
        labels_to_remove << project.automation_label_name
      end

      present_labels = labels_to_remove.uniq.select { |label| issue.has_label?(label) }
      return if present_labels.empty?

      result = client.remove_labels_from_issue(project.full_name, issue.github_number, present_labels)
      Array(result&.fetch(:failed, [])).each do |failure|
        logger.warn(
          message: "agent_execution.remove_trigger_label_failed",
          agent_run_id: agent_run_id,
          issue_number: issue.github_number,
          label: failure[:label],
          error: failure[:error]
        )
      end
    rescue GithubClient::Error => e
      logger.warn(
        message: "agent_execution.remove_trigger_label_failed",
        agent_run_id: agent_run_id,
        issue_number: issue.github_number,
        error: e.message
      )
    end

    # Redacts lines that match known provider-error patterns so raw
    # provider error text (e.g. OpenRouter billing URLs, credit balances)
    # is never posted to public GitHub comments.
    def sanitize_summary_for_github(text)
      return text if text.blank?

      text.each_line.reject { |line| provider_error_redaction_line?(line) }.join.strip
    end

    def post_needs_input_comment(client, agent_run, agent_summary)
      project = agent_run.project
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

      post_issue_explanation_comment(
        client,
        agent_run,
        issue_state: "needs_input",
        marker: NEEDS_INPUT_COMMENT_MARKER,
        message: lines.join("\n"),
        log_message: "agent_execution.needs_input_comment_failed"
      )
    end

    def post_recommend_close_comment(client, agent_run, agent_summary)
      project = agent_run.project
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

      post_issue_explanation_comment(
        client,
        agent_run,
        issue_state: "recommend_close",
        marker: RECOMMEND_CLOSE_COMMENT_MARKER,
        message: lines.join("\n"),
        log_message: "agent_execution.recommend_close_comment_failed"
      )
    end

    def post_no_code_required_comment(client, agent_run, rationale)
      # Redaction can empty an otherwise valid rationale (e.g. one that quotes
      # credit/quota wording); say so rather than posting a blank section.
      sanitized_rationale = sanitize_summary_for_github(rationale).presence ||
        "(The agent's rationale was withheld because it matched provider-error redaction rules. See the run logs.)"

      lines = [
        NO_CODE_REQUIRED_COMMENT_MARKER,
        "**Completed — No Code Change Required**",
        "",
        "The agent determined this issue's work is complete and no code change is required.",
        "",
        "**Rationale:**",
        "",
        sanitized_rationale.truncate(2000),
        "",
        "**Next steps:**",
        "- If this rationale is correct, close the issue.",
        "- If more work is needed, reopen with clarifying details and re-trigger the automation.",
        ""
      ]

      post_issue_explanation_comment(
        client,
        agent_run,
        issue_state: "completed",
        marker: NO_CODE_REQUIRED_COMMENT_MARKER,
        message: lines.join("\n"),
        log_message: "agent_execution.no_code_required_comment_failed"
      )
    end

    # @spec NO-OUTPUT-ISSUE-001 NO-OUTPUT-ISSUE-002 NO-OUTPUT-ISSUE-003
    def post_issue_explanation_comment(client, agent_run, issue_state:, marker:, message:, log_message:)
      project = agent_run.project
      issue = agent_run.issue

      if comment_exists?(client, project, issue, marker)
        clear_issue_explanation_comment_failure!(agent_run)
        return
      end

      client.add_comment(project.full_name, issue.github_number, message)
      clear_issue_explanation_comment_failure!(agent_run)
    rescue GithubClient::Error => e
      record_issue_explanation_comment_failure!(agent_run, issue_state: issue_state, marker: marker, error: e.message)
      logger.warn(
        message: log_message,
        agent_run_id: agent_run.id,
        issue_number: issue.github_number,
        error: e.message
      )
    end

    def record_issue_explanation_comment_failure!(agent_run, issue_state:, marker:, error:)
      metadata = agent_run.external_metadata.is_a?(Hash) ? agent_run.external_metadata.deep_dup : {}
      metadata[ISSUE_EXPLANATION_COMMENT_FAILURE_KEY] = {
        "issue_state" => issue_state,
        "marker" => marker,
        "error" => error.to_s.truncate(500),
        "recorded_at" => Time.current.iso8601
      }
      agent_run.update!(
        error_message: issue_explanation_comment_failure_summary(issue_state),
        external_metadata: metadata
      )
    end

    def clear_issue_explanation_comment_failure!(agent_run)
      metadata = agent_run.external_metadata.is_a?(Hash) ? agent_run.external_metadata.deep_dup : {}
      return unless metadata.delete(ISSUE_EXPLANATION_COMMENT_FAILURE_KEY) || issue_explanation_comment_failure?(agent_run.error_message)

      attributes = { external_metadata: metadata }
      attributes[:error_message] = nil if issue_explanation_comment_failure?(agent_run.error_message)
      agent_run.update!(attributes)
    end

    def issue_explanation_comment_failure_summary(issue_state)
      "#{issue_explanation_comment_failure_label(issue_state)} explanation comment could not be posted to GitHub. Review the run for details."
    end

    def issue_explanation_comment_failure?(error_message)
      error_message.to_s.include?("explanation comment could not be posted to GitHub")
    end

    def issue_explanation_comment_failure_label(issue_state)
      case issue_state
      when "needs_input"
        "Needs-input"
      when "recommend_close"
        "Recommend-close"
      else
        issue_state.to_s.tr("_", "-").humanize
      end
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
