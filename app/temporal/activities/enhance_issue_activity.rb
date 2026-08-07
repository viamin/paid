# frozen_string_literal: true

module Activities
  # Enhances a GitHub issue with knowledge-base-backed implementation context,
  # or asks focused clarifying questions when the issue is not actionable yet.
  class EnhanceIssueActivity < BaseActivity
    include Llm::OutputNormalizer

    activity_name "EnhanceIssue"

    COMMENT_MARKER = "<!-- paid:enhance-issue -->"
    # The containerized agent wraps its JSON result between two
    # OUTPUT_DELIMITER lines so the parser can anchor on it even when the
    # runner interleaves its own log output. Kept in sync with the
    # FALLBACK_ENHANCE_ISSUE_GOAL_PROMPT and the goal.enhance_issue seed.
    OUTPUT_DELIMITER = "paid-enhance-issue-output"
    STDOUT_TAIL_CHUNKS = 50
    MAX_SEARCH_RESULTS = 10
    MAX_COMMENTS = 50
    MAX_COMMENT_BODY = 50_000
    LLM_TIMEOUT = 120
    DEFAULT_PROVIDER = "claude"
    DEFAULT_MODEL = "claude-sonnet-4-6"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)

      track_phase(
        agent_run_id: agent_run_id,
        phase_key: "enhance_issue",
        phase_group: "agent",
        agent_run: agent_run
      ) do
        if input[:post_run]
          enhance_issue_post_run(agent_run)
        else
          enhance_issue_direct(agent_run)
        end
      end
    end

    private

    # Direct LLM path (legacy, kept for backward compatibility during transition).
    def enhance_issue_direct(agent_run)
      agent_run.start!
      project = agent_run.project
      issue = agent_run.issue
      raise ArgumentError, "enhance_issue run requires an issue" unless issue
      ensure_trusted_issue!(issue)

      client = github_client(project)
      comments = trusted_comments(project, client.issue_comments(project.full_name, issue.github_number))
      existing_comment = enhancement_comment(comments)
      return complete_existing(agent_run, client, project, issue, existing_comment) if existing_comment && issue.enhance_issue_rounds.zero?

      context = build_context(agent_run, project, issue)
      response = call_llm(agent_run, prompt_for(project, issue, comments, context))
      parsed = parse_response!(agent_run, response)
      track_tokens(agent_run, response)
      finish_enhance_issue(agent_run, project, issue, client, parsed, context)
    end

    # Post-run path: the agent has already run in the container via
    # RunAgentActivity.  Read its structured JSON output from the run logs
    # and handle comment posting + label state (RDR-052 Phase 1).
    # @spec ISSUE-ENHANCEMENT-006
    def enhance_issue_post_run(agent_run)
      project = agent_run.project
      issue = agent_run.issue
      raise ArgumentError, "enhance_issue run requires an issue" unless issue
      ensure_trusted_issue!(issue)

      client = github_client(project)
      comments = trusted_comments(project, client.issue_comments(project.full_name, issue.github_number))
      existing_comment = enhancement_comment(comments)
      return complete_existing(agent_run, client, project, issue, existing_comment) if existing_comment && issue.enhance_issue_rounds.zero?

      parsed = parse_agent_output!(agent_run)
      context = post_run_context(agent_run, project, issue)
      finish_enhance_issue(agent_run, project, issue, client, parsed, context)
    end

    # Shared post-parse logic: build comment, post, apply labels, complete run.
    def finish_enhance_issue(agent_run, project, issue, client, parsed, context)
      parsed = stop_after_max_rounds(parsed, project, issue)
      draft = build_change_intent_draft(agent_run, project, issue, parsed)
      comment_body = comment_body_for(parsed, draft)
      gh_comment = client.add_comment(project.full_name, issue.github_number, comment_body)
      label_result = apply_label_state(client, project, issue, parsed)

      agent_run.log!("stdout", comment_body)
      complete_run!(agent_run, paid_state_for(parsed, project, issue))
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
        comment_url: gh_comment.html_url,
        knowledge_results: context[:knowledge_results_count] || 0,
        knowledge_sections: context[:bundle_sections] || 0
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
    def parse_agent_output!(agent_run)
      raw = collect_agent_stdout(agent_run)
      raise_parse_error!(agent_run, "no structured output captured") if raw.blank?

      parsed = JSON.parse(strip_markdown_fence(extract_json_payload(raw)), symbolize_names: true)
      return parsed if parsed.key?(:sufficient_context) && parsed[:comment_body].present?

      raise_parse_error!(agent_run, "missing sufficient_context or comment_body")
    rescue JSON::ParserError => e
      raise_parse_error!(agent_run, e.message)
    end

    # Concatenates the recent stdout chunks in chronological order. The runner
    # logs stdout per chunk (Containers::Provision#log_output), so the agent's
    # delimited JSON can span several chunks.
    def collect_agent_stdout(agent_run)
      agent_run.agent_run_logs.stdout.recent.limit(STDOUT_TAIL_CHUNKS).pluck(:content).reverse.join
    end

    # Extracts the JSON payload from concatenated stdout. The agent prompt
    # wraps its JSON between OUTPUT_DELIMITER lines; if no delimiter is
    # present the whole tail is treated as the payload.
    def extract_json_payload(raw)
      match = raw.match(/#{Regexp.escape(OUTPUT_DELIMITER)}\s*(.*?)\s*#{Regexp.escape(OUTPUT_DELIMITER)}/m)
      match ? match[1].strip : raw.strip
    end

    # Fail loudly rather than posting garbled agent output as an enhancement
    # comment. A non-retryable error surfaces the problem for investigation
    # without marking the issue enhanced with unparseable content.
    def raise_parse_error!(agent_run, detail)
      agent_run.log!("stderr", "Failed to parse agent output: #{detail}")
      raise Temporalio::Error::ApplicationError.new(
        "EnhanceIssue agent produced unparseable structured output: #{detail}",
        type: "EnhanceIssueUnparseableOutput",
        non_retryable: true
      )
    end

    # The containerized agent explored the repo directly, so the activity does
    # not re-run a knowledge search for prompt context. It still builds the
    # context bundle so the bundle/section observability metrics stay populated.
    def post_run_context(agent_run, project, issue)
      bundle = context_bundle(agent_run, project, issue)
      { bundle_sections: bundle[:sections], bundle_tokens: bundle[:total_tokens] }
    end

    def complete_existing(agent_run, client, project, issue, existing_comment)
      label_result = reconcile_existing_label_state(client, project, issue, existing_comment)
      complete_run!(agent_run, existing_paid_state(issue, existing_comment))
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

    def reconcile_existing_label_state(client, project, issue, existing_comment)
      if existing_comment.body.to_s.include?("## Auto-enhancement stopped")
        removed = labels_removed(client, project, issue, [ project.enhance_issue_needs_input_label_name ])
        merge_local_labels(issue, remove: removed)
        return { applied: nil, max_rounds_reached: true, sufficient_context: false }
      end

      sufficient_context = !existing_comment.body.to_s.include?("## Clarifying questions")
      result = apply_label_state(client, project, issue, sufficient_context: sufficient_context)
      result.merge(sufficient_context: sufficient_context)
    end

    def existing_paid_state(issue, existing_comment)
      return "completed" if existing_comment.body.to_s.include?("## Auto-enhancement stopped")
      return "needs_input" if issue.has_label?(issue.project.enhance_issue_needs_input_label_name)
      return "needs_input" if existing_comment.body.to_s.include?("## Clarifying questions")

      "completed"
    end

    def complete_run!(agent_run, paid_state = "completed")
      agent_run.complete!
      agent_run.issue.update!(paid_state: paid_state) if agent_run.issue
    end

    def build_context(agent_run, project, issue)
      # @spec KNOWLEDGE-005
      search = knowledge_search(agent_run, project, issue)
      bundle = context_bundle(agent_run, project, issue)

      {
        search_results: search[:results],
        knowledge_results_count: search[:results].size,
        bundle_content: bundle[:content],
        bundle_sections: bundle[:sections],
        bundle_tokens: bundle[:total_tokens]
      }
    end

    def knowledge_search(agent_run, project, issue)
      query = "#{issue.title}\n\n#{issue.body.to_s.truncate(2_000)}"

      Knowledge::Search.call(
        project: project,
        query: query,
        mode: "hybrid",
        limit: MAX_SEARCH_RESULTS,
        agent_run_id: agent_run.id
      )
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      logger.warn(
        message: "agent_execution.enhance_issue_knowledge_search_failed",
        project_id: project.id,
        issue_id: issue.id,
        error_class: e.class.name,
        error: e.message
      )
      { results: [], meta: {} }
    end

    def context_bundle(agent_run, project, issue)
      Knowledge::ContextBundle::Build.call(
        issue: issue,
        project: project,
        agent_run: agent_run,
        agent_run_id: agent_run.id
      )
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      logger.warn(
        message: "agent_execution.enhance_issue_context_bundle_failed",
        project_id: project.id,
        issue_id: issue.id,
        error_class: e.class.name,
        error: e.message
      )
      { content: "", sections: [], total_tokens: 0 }
    end

    def call_llm(agent_run, prompt)
      chat_providers(agent_run.project).each do |provider|
        response = AgentHarness.send_message(prompt, **llm_options(provider))
        return response if !response.respond_to?(:success?) || response.success?

        log_failed_response(agent_run, provider, response)
      rescue AgentHarness::Error => e
        logger.warn(
          message: "agent_execution.enhance_issue_provider_failed",
          agent_run_id: agent_run.id,
          provider: provider,
          error_class: e.class.name,
          error: e.message
        )
      end

      raise Temporalio::Error::ApplicationError.new(
        "No LLM provider produced an issue enhancement",
        type: "EnhanceIssueLlmFailed",
        non_retryable: true
      )
    end

    def chat_providers(project)
      setting = project.effective_owner&.settings
      providers = setting ? Knowledge::ProviderSelector.for_chat(user_setting: setting) : []
      providers.presence || [ DEFAULT_PROVIDER ]
    end

    def llm_options(provider)
      options = {
        provider: RunnerSupport.harness_runner_key_for(provider).to_sym,
        timeout: LLM_TIMEOUT,
        dangerous_mode: false,
        tools: :none
      }
      options[:model] = DEFAULT_MODEL if provider == DEFAULT_PROVIDER
      options.merge!(Llm::TextMode.options) if provider == DEFAULT_PROVIDER
      options
    end

    # @spec ISSUE-ENHANCEMENT-001
    # @spec ISSUE-ENHANCEMENT-002
    # @spec CHANGE-INTENT-004
    #
    # Today `enhance_issue` runs as a direct LLM call (`tools: :none`,
    # no repository clone — `enhance_issue` is in `skip_clone` in
    # `agent_execution_workflow.rb`). The agent's only codebase view is
    # the supplied retrieval results and knowledge-base context bundle.
    # ISSUE-ENHANCEMENT-006 / 007 (codebase-grounded self-answering and
    # sufficiency judgment) depend on RDR-052 Phase 1
    # (`enhance_issue` in a read-only container with repo access) and
    # land with #3254; until then the prompt frames grounding as
    # knowledge-base-grounded, not repo-exploration-grounded.
    def prompt_for(project, issue, comments, context)
      <<~PROMPT
        You analyze a GitHub issue for implementation readiness, grounded in the
        knowledge-base context supplied below. You do not have repository access
        in this run, so use the retrieval results and context bundle to inform
        your verdict rather than claiming to read the repository directly.

        #{grounding_instructions(issue)}
        #{output_contract}
        ## Repository
        #{project.full_name}

        ## Issue
        Title: #{issue.title}
        Number: ##{issue.github_number}
        Author: #{issue.github_creator_login}

        #{issue.body.to_s.truncate(20_000)}

        ## Conversation
        #{format_comments(comments)}

        ## Retrieval Results
        #{format_search_results(context[:search_results])}

        #{context[:bundle_content].presence || "No context bundle entries were available."}
      PROMPT
    end

    # @spec ISSUE-ENHANCEMENT-001
    def grounding_instructions(issue)
      <<~INSTRUCTIONS
        Use the retrieval results and knowledge-base context below to inform
        your verdict. Do not invent facts about the repository — if the supplied
        context is silent on something, treat it as unknown rather than guessing.

        Ask the human ONLY about genuine product, scope, or intent ambiguities.
        Do not use Linked-Intent Development or other process jargon.
        Prefer questions that uncover:
        - the problem being solved,
        - the desired behavior, ideally phrased as "when X happens, the system should Y",
        - constraints or non-negotiables,
        - alternatives that were considered or rejected,
        - what is in scope versus out of scope,
        - how the user will know the work is done.
        #{reevaluation_guidance(issue)}
      INSTRUCTIONS
    end

    # @spec ISSUE-ENHANCEMENT-005
    def reevaluation_guidance(issue)
      return "" unless issue.enhance_issue_rounds.positive?

      <<~GUIDANCE
        This is a re-evaluation after the human answered earlier questions. The
        conversation below contains the prior questions and answers. Judge
        whether the user's answers TOGETHER WITH the supplied knowledge-base
        context yield enough context to proceed — do not re-ask a question a
        prior answer already resolved.
      GUIDANCE
    end

    # @spec ISSUE-ENHANCEMENT-002
    def output_contract
      <<~CONTRACT
        Respond with ONLY valid JSON:
        {
          "sufficient_context": true or false,
          "comment_body": "Markdown comment to post on the issue",
          "change_intent_draft": {
            "title": "Short title of the constraint or rejected alternative",
            "intent": "What the human was trying to accomplish",
            "behavior": "Expected behavior or scenarios, when applicable",
            "constraints": "The non-obvious constraint or requirement",
            "decisions_made": "Which reasonable alternative was rejected and why"
          }
        }

        The "change_intent_draft" is OPTIONAL. Include it only when the issue
        contains a non-obvious constraint or a rejected reasonable alternative
        that a future contributor might overlook and try a different way. Do not
        include it when the constraint is self-evident, obvious from the code, or
        no alternative was actually rejected — more records means more noise. This
        judgment is independent of whether the issue has sufficient implementation
        context.

        The comment_body must follow one of these structures:

        If sufficient_context is true:
        ## Implementation context
        ### Relevant files and symbols
        - ...
        ### Architecture notes
        - ...
        ### Suggested approach
        1. ...
        ### Related context
        - ...

        Ground "Relevant files and symbols" and "Architecture notes" in the
        files, types, and patterns surfaced by the retrieval results and
        knowledge-base context supplied below — cite paths and symbols that
        appear in that context, not invented references.

        If sufficient_context is false:
        ## Clarifying questions
        1. ...
        ## Current context
        - ...

        Keep the comment concise, actionable, and grounded in the supplied context.
      CONTRACT
    end

    def format_comments(comments)
      relevant = comments.last(MAX_COMMENTS)
      return "No comments." if relevant.empty?

      relevant.map do |comment|
        author = comment.user&.login || "unknown"
        created = comment.created_at || "unknown time"
        body = comment.body.to_s.truncate(2_000)
        "### #{author} at #{created}\n#{body}"
      end.join("\n\n")
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

    def format_search_results(results)
      return "No retrieval results." if results.empty?

      results.map do |result|
        title = result[:title] || result[:identifier] || result[:artifact_type] || "Knowledge result"
        path = result[:path] || result[:scope_path]
        content = result[:content].to_s.truncate(1_500)
        [ "### #{title}", ("Path: #{path}" if path.present?), content ].compact.join("\n")
      end.join("\n\n")
    end

    def parse_response!(agent_run, response)
      output = response.respond_to?(:output) ? response.output.to_s : response.to_s
      parsed = JSON.parse(strip_markdown_fence(output.to_s.strip), symbolize_names: true)
      return parsed if parsed.key?(:sufficient_context) && parsed[:comment_body].present?

      raise JSON::ParserError, "missing sufficient_context or comment_body"
    rescue JSON::ParserError => e
      agent_run.log!("stderr", "Failed to parse enhancement response: #{e.message}")
      raise Temporalio::Error::ApplicationError.new(
        "LLM returned invalid enhancement JSON",
        type: "EnhanceIssueInvalidJson",
        non_retryable: true
      )
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
      return "completed" if max_rounds_reached?(project, issue)

      "needs_input"
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

    def track_tokens(agent_run, response)
      return unless response.respond_to?(:tokens) && response.tokens

      TokenUsageTracker.track(
        tracked_run: agent_run,
        usage: {
          tokens_input: response.respond_to?(:input_tokens) ? response.input_tokens.to_i : 0,
          tokens_output: response.respond_to?(:output_tokens) ? response.output_tokens.to_i : 0,
          llm_model: response.respond_to?(:model) ? response.model : nil,
          request_type: "agent",
          metadata: { operation: "enhance_issue" }
        }
      )
    end

    def github_client(project)
      project.client
    end

    def log_failed_response(agent_run, provider, response)
      logger.warn(
        message: "agent_execution.enhance_issue_llm_failed",
        agent_run_id: agent_run.id,
        provider: provider,
        error: response.respond_to?(:error) ? response.error : nil,
        exit_code: response.respond_to?(:exit_code) ? response.exit_code : nil
      )
    end
  end
end
