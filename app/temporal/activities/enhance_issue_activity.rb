# frozen_string_literal: true

module Activities
  # Enhances a GitHub issue with knowledge-base-backed implementation context,
  # or asks focused clarifying questions when the issue is not actionable yet.
  #
  # Containerized execution: the agent has already explored the repo in a
  # comment-only containerized run via RunAgentActivity (RDR-052 Phase 1) and
  # emitted a structured JSON result between OUTPUT_DELIMITER lines. The
  # workspace mount is :rw so the platform could clone into /workspace, but
  # RunAgentActivity skipped git post-processing and the prompt instructed
  # the agent not to commit/push. This activity reads that result, posts the
  # enhancement comment, and applies label state.
  # @spec ISSUE-ENHANCEMENT-006
  class EnhanceIssueActivity < BaseActivity
    include Llm::OutputNormalizer

    activity_name "EnhanceIssue"

    COMMENT_MARKER = "<!-- paid:enhance-issue -->"
    MANUAL_REVIEW_MARKER = IssueEnhancements::StopForManualReview::COMMENT_MARKER
    # The containerized agent wraps its JSON result between two
    # OUTPUT_DELIMITER lines so the parser can anchor on it even when the
    # runner interleaves its own log output. Kept in sync with the
    # FALLBACK_ENHANCE_ISSUE_GOAL_PROMPT and the goal.enhance_issue seed.
    OUTPUT_DELIMITER = "paid-enhance-issue-output"
    DELIMITED_OUTPUT_PATTERN = /^#{Regexp.escape(OUTPUT_DELIMITER)}[ \t]*\r?$\R(.*?)^#{Regexp.escape(OUTPUT_DELIMITER)}[ \t]*\r?$/m
    STDOUT_TAIL_CHUNKS = 50
    MAX_COMMENT_BODY = 50_000
    # Assistant-message JSONL shapes recognized across runners: a bare
    # "agent_message"/"task_complete"/"turn_complete" event (including the
    # dotted "turn.complete"/"turn.completed" spellings some runners emit,
    # matching Containers::StreamingEventProcessor::TURN_COMPLETE_EVENT_TYPES),
    # or an envelope carrying one of these (e.g. Codex's "item.completed" ->
    # "item", "event_msg" -> "payload", "response_item" -> "payload"). Mirrors
    # the shapes AgentRun's stdout normalizer already recognizes (see
    # spec/models/agent_run_spec.rb) so a delimited payload isn't missed just
    # because a runner nests its final message differently than the one we
    # happened to check for.
    ASSISTANT_MESSAGE_TYPES = %w[agent_message task_complete turn_complete turn.complete turn.completed].freeze

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)

      track_phase(
        agent_run_id: agent_run_id,
        phase_key: "enhance_issue",
        phase_group: "agent",
        agent_run: agent_run
      ) do
        enhance_issue_post_run(agent_run)
      end
    end

    private

    # Reads the containerized agent's structured JSON output from the run
    # logs, posts the enhancement comment, and applies label state.
    # @spec ISSUE-ENHANCEMENT-006
    def enhance_issue_post_run(agent_run)
      project = agent_run.project
      issue = agent_run.issue
      raise ArgumentError, "enhance_issue run requires an issue" unless issue
      ensure_trusted_issue!(issue)

      client = github_client(project)
      raw_comments = client.issue_comments(project.full_name, issue.github_number)
      comments = trusted_comments(project, raw_comments)
      existing_comment = enhancement_comment(comments)
      return complete_existing(agent_run, client, project, issue, existing_comment) if existing_comment && issue.enhance_issue_rounds.zero?

      parsed = parse_agent_output!(agent_run, project, issue, client, raw_comments)
      return parsed if parsed[:recovered_paid_question_comment]

      finish_enhance_issue(agent_run, project, issue, client, parsed)
    end

    # Build comment, post, apply labels, complete run.
    # @spec ISSUE-ENHANCEMENT-006
    def finish_enhance_issue(agent_run, project, issue, client, parsed)
      max_rounds_reached = !parsed[:sufficient_context] && max_rounds_reached?(project, issue)
      parsed = stop_after_max_rounds(parsed, project, issue)
      draft = build_change_intent_draft(agent_run, project, issue, parsed)
      comment_body = comment_body_for(parsed, draft)
      questions = needs_input_questions(parsed, comment_body, max_rounds_reached:)
      raise_parse_error!(agent_run, "sufficient_context false without clarifying questions") if needs_questions?(parsed, max_rounds_reached) && questions.empty?

      gh_comment = client.add_comment(project.full_name, issue.github_number, comment_body)
      label_result = apply_label_state(client, project, issue, parsed)
      sync_needs_input_questions(issue, questions)

      agent_run.log!("stdout", comment_body)
      complete_run!(agent_run, paid_state_for(parsed, project, issue), reason: (max_rounds_reason(project) if max_rounds_reached))
      ProcessRunQueueJob.perform_later

      logger.info(
        message: "agent_execution.issue_enhanced",
        agent_run_id: agent_run.id,
        issue_id: issue.id,
        issue_number: issue.github_number,
        sufficient_context: parsed[:sufficient_context],
        label_applied: label_result[:applied],
        max_rounds_reached: label_result[:max_rounds_reached],
        enhance_issue_rounds: issue.enhance_issue_rounds,
        comment_url: gh_comment.html_url
      )

      {
        agent_run_id: agent_run.id,
        issue_number: issue.github_number,
        comment_url: gh_comment.html_url,
        sufficient_context: parsed[:sufficient_context],
        label_applied: label_result[:applied],
        max_rounds_reached: label_result[:max_rounds_reached]
      }
    end

    # Reads the agent's structured JSON output from the run logs and parses it.
    # The agent (run via RunAgentActivity) emits its JSON between
    # OUTPUT_DELIMITER lines so it survives runner log noise and chunking.
    # @spec ISSUE-ENHANCEMENT-006
    def parse_agent_output!(agent_run, project, issue, client, comments)
      raw = collect_agent_stdout(agent_run)
      return recover_or_raise_parse_error!(agent_run, project, issue, client, comments, "no structured output captured") if raw.blank?

      parsed = JSON.parse(strip_markdown_fence(extract_json_payload(raw)), symbolize_names: true)
      return parsed if valid_structured_output?(parsed)

      recover_or_raise_parse_error!(agent_run, project, issue, client, comments, "sufficient_context must be boolean and comment_body must be a non-empty string", discarded_valid_payload: discarded_valid_delimited_payload?(raw))
    rescue JSON::ParserError => e
      recover_or_raise_parse_error!(agent_run, project, issue, client, comments, e.message, discarded_valid_payload: discarded_valid_delimited_payload?(raw))
    end

    # Reads recent stdout through AgentRun's provider-aware output normalizer.
    # Structured runners may wrap the final agent message in JSONL events, while
    # text runners return the delimited payload directly.
    # @spec ISSUE-ENHANCEMENT-006
    def collect_agent_stdout(agent_run)
      raw = agent_run.agent_run_logs.stdout.recent.limit(STDOUT_TAIL_CHUNKS).pluck(:content).reverse.join
      return raw if delimited_payload(raw)

      agent_run.normalized_agent_output(raw, succeeded: true)
    end

    # Extracts the JSON payload from concatenated stdout. The agent prompt
    # wraps its JSON between OUTPUT_DELIMITER lines; if no delimiter is
    # present the whole tail is treated as the payload.
    def extract_json_payload(raw)
      delimited_payload(raw) || raw.strip
    end

    # Looks for our own delimited payload before falling back to a runner's
    # generic output normalizer. Checks JSONL-wrapped agent messages first:
    # structured runners (OpenCode/Codex) emit one JSON event per physical
    # line, so the delimiter's newlines are escaped inside a string field and
    # never match DELIMITED_OUTPUT_PATTERN's line anchors directly against the
    # raw JSONL. Runner-side turn-selection logic can also pick an earlier
    # progress message instead of the final one (#3786); scanning every
    # agent_message event ourselves and keeping the last delimiter match
    # sidesteps that without needing to replicate runner-specific turn
    # semantics.
    # @spec ISSUE-ENHANCEMENT-006
    def delimited_payload(raw)
      @delimited_payloads ||= {}
      @delimited_payloads.fetch(raw) { @delimited_payloads[raw] = jsonl_delimited_payload(raw) || plain_delimited_payload(raw) }
    end

    def plain_delimited_payload(raw)
      delimited_payload_matches(raw).last
    end

    # Every delimited payload in the given text, in encounter order. The
    # extraction keeps only the last match; the refund check needs all of
    # them to tell a valid discarded payload from an invalid kept one.
    def delimited_payload_matches(text)
      text.scan(DELIMITED_OUTPUT_PATTERN).map { |match| match[0].strip }
    end

    def jsonl_delimited_payload(raw)
      payload = nil
      raw.each_line do |line|
        text = agent_message_text(line)
        next unless text

        match = plain_delimited_payload(text)
        payload = match if match
      end
      payload
    end

    # Recognizes a top-level agent-message event or one nested in an
    # envelope (e.g. `item.completed`'s `item`, or `event_msg`/`response_item`'s
    # `payload`).
    def agent_message_text(line)
      event = JSON.parse(line)
      return unless event.is_a?(Hash)

      agent_message_item_text(event) ||
        agent_message_item_text(event["item"]) ||
        agent_message_item_text(event["payload"])
    rescue JSON::ParserError
      nil
    end

    def agent_message_item_text(item)
      return unless item.is_a?(Hash)
      return unless item["type"].in?(ASSISTANT_MESSAGE_TYPES) || item["role"] == "assistant"

      text = item["text"] || item["message"] || item["last_agent_message"] || item["result"] || content_block_text(item["content"])
      text if text.is_a?(String) && text.present?
    end

    def content_block_text(content)
      return unless content.is_a?(Array)

      content.filter_map { |block| block["text"] if block.is_a?(Hash) && block["type"] == "output_text" }.join.presence
    end

    # Whether the collected stdout contained a delimited payload that
    # satisfies the structured-output contract even though the parse path
    # failed — i.e. Paid's extraction (which keeps only the last delimiter
    # match) demonstrably discarded a valid payload. A delimited payload
    # that is itself malformed JSON or omits the required keys is an agent
    # contract failure, not an extraction defect, and does not refund.
    def discarded_valid_delimited_payload?(raw)
      recognized_delimited_payloads(raw).any? { |payload| valid_delimited_payload_text?(payload) }
    end

    # Every delimited payload the extraction recognizes in the given stdout,
    # in encounter order: matches embedded in recognized assistant-message
    # JSONL events plus plain-text matches on the raw text itself.
    def recognized_delimited_payloads(raw)
      payloads = []
      raw.each_line do |line|
        text = agent_message_text(line)
        payloads.concat(delimited_payload_matches(text)) if text
      end
      payloads.concat(delimited_payload_matches(raw))
    end

    def valid_delimited_payload_text?(payload_text)
      valid_structured_output?(JSON.parse(strip_markdown_fence(payload_text), symbolize_names: true))
    rescue JSON::ParserError
      false
    end

    def valid_structured_output?(parsed)
      parsed.is_a?(Hash) &&
        parsed[:sufficient_context].in?([ true, false ]) &&
        parsed[:comment_body].is_a?(String) &&
        parsed[:comment_body].present?
    end

    # Fail loudly rather than posting garbled agent output as an enhancement
    # comment. A non-retryable error surfaces the problem for investigation
    # without marking the issue enhanced with unparseable content.
    #
    # A round is refunded only when Paid demonstrably discarded a valid
    # delimited payload — the stdout contained one that satisfies the
    # structured-output contract, yet the parse path still failed. That is
    # Paid's extraction bug, not the agent's, so it must not burn budget
    # meant to bound repeated automatic re-evaluation (see #3652). Malformed
    # JSON or missing keys inside the delimiters is an agent contract
    # failure and consumes the round. Only automatic runs consume a round at
    # queue time (manual runs never do, ISSUE-ENHANCEMENT-011), so only
    # automatic runs may refund one.
    def raise_parse_error!(agent_run, detail, discarded_valid_payload: false)
      if agent_run.issue
        IssueEnhancements::StopForManualReview.call(
          project: agent_run.project,
          issue: agent_run.issue,
          reason: "Paid could not validate the enhancement agent's structured output."
        )
        refund_enhancement_round!(agent_run.issue) if discarded_valid_payload && agent_run.automatic?
      end
      agent_run.log!("stderr", "Failed to parse agent output: #{detail}")
      raise Temporalio::Error::ApplicationError.new(
        "EnhanceIssue agent produced unparseable structured output: #{detail}",
        type: "EnhanceIssueUnparseableOutput",
        non_retryable: true
      )
    end

    def refund_enhancement_round!(issue)
      issue.with_lock do
        next if issue.enhance_issue_rounds <= 0

        issue.update!(enhance_issue_rounds: issue.enhance_issue_rounds - 1)
      end
    end

    def recover_or_raise_parse_error!(agent_run, project, issue, client, comments, detail, discarded_valid_payload: false)
      comment = paid_question_comment(project, agent_run, comments)
      return recover_paid_question_comment!(agent_run, project, issue, client, comment) if comment

      raise_parse_error!(agent_run, detail, discarded_valid_payload: discarded_valid_payload)
    end

    def recover_paid_question_comment!(agent_run, project, issue, client, comment)
      label_result = apply_label_state(client, project, issue, sufficient_context: false)
      issue.update!(needs_input_questions: paid_comment_questions(comment))
      complete_run!(agent_run, "needs_input")
      ProcessRunQueueJob.perform_later

      agent_run.log!("system", "Recovered Paid-authored clarifying question comment: #{comment.html_url}")
      logger.info(
        message: "agent_execution.enhance_issue_recovered_paid_question_comment",
        agent_run_id: agent_run.id,
        issue_id: issue.id,
        issue_number: issue.github_number,
        comment_url: comment.html_url
      )

      {
        agent_run_id: agent_run.id,
        issue_number: issue.github_number,
        comment_url: comment.html_url,
        sufficient_context: false,
        label_applied: label_result[:applied],
        max_rounds_reached: label_result[:max_rounds_reached],
        recovered_paid_question_comment: true
      }
    end

    def complete_existing(agent_run, client, project, issue, existing_comment)
      label_result = reconcile_existing_label_state(client, project, issue, existing_comment)
      paid_state = existing_paid_state(issue, existing_comment)
      complete_run!(agent_run, paid_state, reason: (issue.manual_review_reason if paid_state == "manual_review"))
      agent_run.log!("system", "Enhancement comment already exists: #{existing_comment.html_url}")
      ProcessRunQueueJob.perform_later

      {
        agent_run_id: agent_run.id,
        issue_number: issue.github_number,
        comment_url: existing_comment.html_url,
        sufficient_context: label_result[:sufficient_context],
        label_applied: label_result[:applied],
        max_rounds_reached: label_result[:max_rounds_reached],
        already_enhanced: true
      }
    end

    # `## Auto-enhancement stopped` markers can be posted by either the
    # max-rounds path (max_rounds_reason) or raise_parse_error! (the
    # "Paid could not validate..." reason). On a retry that re-enters this
    # branch, the reason the issue was originally parked with is the source
    # of truth — overwrite it with the round-limit copy and the inbox lane
    # will show operators the wrong cause.
    def reconcile_existing_label_state(client, project, issue, existing_comment)
      if existing_comment.body.to_s.include?("## Auto-enhancement stopped")
        removed = labels_removed(client, project, issue, [ project.enhance_issue_needs_input_label_name ])
        merge_local_labels(issue, remove: removed)
        attrs = { paid_state: "manual_review" }
        attrs[:manual_review_reason] = max_rounds_reason(project) if issue.manual_review_reason.blank?
        issue.update!(attrs)
        return { applied: nil, max_rounds_reached: true, sufficient_context: false }
      end

      sufficient_context = !existing_comment.body.to_s.include?("## Clarifying questions")
      result = apply_label_state(client, project, issue, sufficient_context: sufficient_context)
      result.merge(sufficient_context: sufficient_context)
    end

    def existing_paid_state(issue, existing_comment)
      return "manual_review" if existing_comment.body.to_s.include?("## Auto-enhancement stopped")
      return "needs_input" if issue.has_label?(issue.project.enhance_issue_needs_input_label_name)
      return "needs_input" if existing_comment.body.to_s.include?("## Clarifying questions")

      "completed"
    end

    def complete_run!(agent_run, paid_state = "completed", reason: nil)
      agent_run.complete!
      return unless agent_run.issue

      attrs = { paid_state: paid_state }
      attrs[:manual_review_reason] = reason if reason
      agent_run.issue.update!(attrs)
    end

    # Shared with stop_after_max_rounds' GitHub comment copy, so the persisted
    # reason (surfaced in the inbox) and the public comment tell the operator
    # the same story.
    # @spec ISSUE-ENHANCEMENT-012
    def max_rounds_reason(project)
      "Paid reached the configured limit of #{project.max_enhance_issue_reevaluation_rounds} " \
        "enhancement re-evaluation rounds for this issue."
    end

    def trusted_comments(project, comments)
      # Admit trusted human collaborators plus Paid's own structured marker
      # comments (clarifying questions/answers) authored by the project's
      # GitHub App bot. trusted_github_user? deliberately excludes the bot, so
      # without this re-admission the re-evaluation LLM never sees the prior
      # Q&A it posted and re-asks the same questions. See CommentAdmission and
      # Project#paid_bot_author?.
      comments.select { |comment| ClarifyingQuestions::CommentAdmission.admissible?(project:, comment:) }
    end

    def comment_body_for(parsed, draft = nil)
      sections = [ COMMENT_MARKER, parsed[:comment_body].to_s.truncate(MAX_COMMENT_BODY) ]
      sections << change_intent_section(draft) if draft
      sections.join("\n\n")
    end

    # @spec CHANGE-INTENT-004
    def build_change_intent_draft(agent_run, project, issue, parsed)
      payload = parsed[:change_intent_draft]
      return unless payload

      ChangeIntents::DraftFromIssue.call(project: project, issue: issue, payload: payload).tap do |draft|
        next unless draft

        logger.info(
          message: "agent_execution.enhance_issue_cir_drafted",
          agent_run_id: agent_run.id,
          project_id: project.id,
          issue_id: issue.id,
          change_intent_id: draft.id
        )
      end
    rescue ActiveRecord::RecordInvalid => e
      logger.warn(
        message: "agent_execution.enhance_issue_cir_draft_failed",
        agent_run_id: agent_run.id,
        project_id: project.id,
        issue_id: issue.id,
        error: e.message
      )
      nil
    end

    def change_intent_section(draft)
      review_url = change_intent_review_url(draft.project, draft)
      lines = [
        "## Proposed Change Intent Record",
        "",
        "This issue contains a non-obvious constraint worth preserving for future work.",
        "",
        "**#{draft.title}**",
        "",
        draft.intent
      ]
      lines << "**Constraints:** #{draft.constraints}" if draft.constraints.present?
      lines << "**Rejected alternatives:** #{draft.decisions_made}" if draft.decisions_made.present?
      lines << ""
      lines << "Review and approve or discard this proposal: #{review_url}"
      lines.join("\n")
    end

    def change_intent_review_url(project, change_intent)
      helpers.project_change_intent_url(project, change_intent, **url_host_options)
    rescue ArgumentError
      helpers.project_change_intent_path(project, change_intent)
    end

    def url_host_options
      ActionMailer::Base.default_url_options.slice(:host, :port)
    end

    def helpers
      Rails.application.routes.url_helpers
    end

    def stop_after_max_rounds(parsed, project, issue)
      return parsed if parsed[:sufficient_context]
      return parsed unless max_rounds_reached?(project, issue)

      parsed.merge(
        comment_body: <<~COMMENT
          #{MANUAL_REVIEW_MARKER}
          ## Auto-enhancement stopped

          Paid has reached the configured limit of #{project.max_enhance_issue_reevaluation_rounds} enhancement re-evaluation rounds for this issue.

          Manual review is needed before enhancement can continue.

          ## Latest context
          #{parsed[:comment_body]}
        COMMENT
      )
    end

    def enhancement_comment(comments)
      comments.find { |comment| comment.body.to_s.include?(COMMENT_MARKER) }
    end

    def ensure_trusted_issue!(issue)
      return if issue.trusted?

      logger.warn(
        message: "agent_execution.enhance_issue_untrusted_issue_rejected",
        issue_id: issue.id,
        creator: issue.github_creator_login
      )
      raise Temporalio::Error::ApplicationError.new(
        "Cannot enhance issue from untrusted user: #{issue.github_creator_login}",
        type: "UntrustedIssue",
        non_retryable: true
      )
    end

    def apply_label_state(client, project, issue, parsed)
      if parsed[:sufficient_context]
        added = labels_added(client, project, issue, [ project.enhance_issue_enhanced_label_name ])
        require_label_added!(project.enhance_issue_enhanced_label_name, added)
        removed = labels_removed(client, project, issue, [ project.enhance_issue_needs_input_label_name ])
        merge_local_labels(issue, add: added, remove: removed)
        return { applied: added.first, max_rounds_reached: false }
      end

      if max_rounds_reached?(project, issue)
        removed = labels_removed(client, project, issue, [ project.enhance_issue_needs_input_label_name ])
        merge_local_labels(issue, remove: removed)
        return { applied: nil, max_rounds_reached: true }
      end

      added = labels_added(client, project, issue, [ project.enhance_issue_needs_input_label_name ])
      require_label_added!(project.enhance_issue_needs_input_label_name, added)
      removed = labels_removed(client, project, issue, [ project.enhance_issue_enhanced_label_name ])
      merge_local_labels(issue, add: added, remove: removed)
      { applied: added.first, max_rounds_reached: false }
    end

    def paid_state_for(parsed, project, issue)
      return "completed" if parsed[:sufficient_context]
      return "manual_review" if max_rounds_reached?(project, issue)

      "needs_input"
    end

    def needs_input_questions(parsed, comment_body, max_rounds_reached:)
      return [] unless needs_questions?(parsed, max_rounds_reached)

      ClarifyingQuestions::Parse.call(comment_body:)
    end

    def needs_questions?(parsed, max_rounds_reached)
      !parsed[:sufficient_context] && !max_rounds_reached
    end

    def sync_needs_input_questions(issue, questions)
      issue.update!(needs_input_questions: questions.presence)
    end

    def max_rounds_reached?(project, issue)
      issue.enhance_issue_rounds >= project.max_enhance_issue_reevaluation_rounds
    end

    def add_label(client, project, issue, label)
      client.add_labels_to_issue(project.full_name, issue.github_number, [ label ])
      true
    rescue GithubClient::Error => e
      logger.warn(
        message: "agent_execution.enhance_issue_label_add_failed",
        project_id: project.id,
        issue_id: issue.id,
        label: label,
        error_class: e.class.name,
        error: e.message
      )
      false
    end

    def remove_label(client, project, issue, label)
      return true unless issue.has_label?(label)

      client.remove_label_from_issue(project.full_name, issue.github_number, label)
      true
    rescue GithubClient::NotFoundError
      true
    rescue GithubClient::Error => e
      logger.warn(
        message: "agent_execution.enhance_issue_label_remove_failed",
        project_id: project.id,
        issue_id: issue.id,
        label: label,
        error_class: e.class.name,
        error: e.message
      )
      false
    end

    def labels_added(client, project, issue, labels)
      Projects::EnsureStandardLabels.call_best_effort(project: project, logger: logger)
      labels.select { |label| add_label(client, project, issue, label) }
    end

    def require_label_added!(label, added)
      return if added.include?(label)

      raise Temporalio::Error::ApplicationError.new(
        "Failed to apply enhance_issue control label #{label}",
        type: "EnhanceIssueLabelAddFailed"
      )
    end

    def labels_removed(client, project, issue, labels)
      labels.select { |label| remove_label(client, project, issue, label) }
    end

    def merge_local_labels(issue, add: [], remove: [])
      return if add.empty? && remove.empty?

      labels = (Array(issue.labels) - remove) | add
      issue.update!(labels: labels)
    end

    def paid_question_comment(project, agent_run, comments)
      comments.reverse.find do |comment|
        paid_bot_comment?(project, comment) &&
          comment_after_run?(comment, agent_run) &&
          paid_comment_questions(comment).present?
      end
    end

    def paid_comment_questions(comment)
      body = comment.body.to_s
      questions = ClarifyingQuestions::Parse.call(comment_body: body)
      return questions if questions.any?

      ClarifyingQuestions::Parse.call(comment_body: "#{COMMENT_MARKER}\n#{body}")
    end

    def paid_bot_comment?(project, comment)
      project.paid_bot_author?(comment.user&.login)
    end

    def comment_after_run?(comment, agent_run)
      created_at = comment.created_at
      created_at && created_at.to_time >= agent_run.created_at
    end

    def github_client(project)
      project.client
    end
  end
end
