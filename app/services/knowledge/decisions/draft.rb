# frozen_string_literal: true

module Knowledge
  module Decisions
    # Drafts a decision record from a completed agent run.
    #
    # Summarizes the agent run's changes and calls agent-harness to generate
    # a structured decision record, then stores it as a DecisionRecord with
    # links to the agent run, issue, and a KnowledgeArtifact for search.
    #
    # When Docker is available, the LLM call runs inside an isolated container
    # that authenticates to the secrets proxy via a KnowledgeRun proxy token
    # (no API keys in container). Falls back to in-process AgentHarness when
    # Docker is unavailable.
    #
    # Text-mode routing (#1147): the in-process Claude path opts into
    # +Llm::TextMode.options+ so host-side drafting uses the HTTP text
    # transport when +ANTHROPIC_API_KEY+ is configured. Non-Claude providers
    # and the containerized path continue to use their existing CLI transport
    # unchanged, because +TextTransport+ is Anthropic-only and the container
    # already isolates +cwd+/memory concerns.
    #
    # @example
    #   Knowledge::Decisions::Draft.call(agent_run: agent_run)
    class Draft
      TIMEOUT = 30
      DEFAULT_MODEL = "claude-sonnet-4-6"
      DEFAULT_PROVIDER = "claude"

      PROMPT_SLUG = "knowledge.draft_decision"

      # Fallback used only if the seeded prompt is missing or deactivated.
      # The active template lives in db/seeds/prompts.rb under PROMPT_SLUG.
      FALLBACK_PROMPT = <<~PROMPT
        You are drafting a Decision Record (ADR-lite) for a code change.

        Given the following context about an agent run that created a pull request,
        produce a structured decision record in JSON format with these fields:
        - title: A concise title for the decision (max 100 chars)
        - summary: 1-3 sentence summary of what was decided
        - context: Background/situation that led to this decision
        - decision: What was decided and implemented
        - consequences: Expected outcomes and trade-offs
        - tags: Array of relevant tags (e.g., ["auth", "api", "performance"])

        Respond with ONLY valid JSON, no markdown fences or extra text.

        ## Agent Run Context
        Issue: {{issue_title}}
        PR Changes Summary:
        {{changes_summary}}
      PROMPT

      attr_reader :agent_run

      def initialize(agent_run:)
        @agent_run = agent_run
      end

      def self.call(...)
        new(...).call
      end

      def call
        changes_summary = agent_run.agent_summary_with_stderr_fallback(limit: 200)
        return nil if changes_summary.blank?

        prompt = build_prompt(changes_summary)
        parsed = draft_decision_record(prompt)
        return nil unless parsed

        record = create_decision_record(parsed)
        record_llm_output_metric(record) if record
        record
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error(
          message: "knowledge.decisions.draft_failed",
          agent_run_id: agent_run.id,
          error_class: e.class.name,
          error: e.message
        )
        nil
      end

      private

      def build_prompt(changes_summary)
        vars = {
          issue_title: agent_run.issue&.title || "N/A",
          changes_summary: changes_summary.truncate(10_000)
        }

        Prompts::Render.call(
          slug: PROMPT_SLUG,
          project: agent_run.project,
          variables: vars,
          fallback: -> { Prompts::Render.interpolate(FALLBACK_PROMPT, vars) }
        )
      end

      def send_to_llm(prompt)
        if Knowledge::AnalysisRunner.available?
          send_to_llm_containerized(prompt)
        else
          send_to_llm_in_process(prompt)
        end
      end

      def send_to_llm_containerized(prompt)
        knowledge_run = create_knowledge_run!

        runner = Knowledge::AnalysisRunner.new(
          project: agent_run.project,
          knowledge_run: knowledge_run
        )

        runner.with_container do |r|
          chat_providers.each do |provider|
            next unless Knowledge::AnalysisRunner.supported_provider?(provider)

            output = r.call_llm(
              prompt,
              provider: provider,
              model: model_for(provider),
              timeout: TIMEOUT
            )

            parsed = parse_text_output(output)
            return parsed if parsed
          rescue Knowledge::AnalysisRunner::Error => e
            Rails.logger.warn(
              message: "knowledge.decisions.draft_container_provider_failed",
              agent_run_id: agent_run.id,
              provider: provider,
              error_class: e.class.name,
              error: e.message
            )
          end
        end

        nil
      rescue Knowledge::AnalysisRunner::Error => e
        Rails.logger.warn(
          message: "knowledge.decisions.draft_container_failed",
          agent_run_id: agent_run.id,
          error_class: e.class.name,
          error: e.message
        )
        send_to_llm_in_process(prompt)
      ensure
        finalize_knowledge_run!(knowledge_run)
      end

      def send_to_llm_in_process(prompt)
        chat_providers.each do |provider|
          response = AgentHarness.send_message(
            prompt,
            **llm_request_options(provider)
          )

          parsed = parse_response(response)
          return parsed if parsed
        rescue AgentHarness::Error => e
          Rails.logger.warn(
            message: "knowledge.decisions.draft_provider_failed",
            agent_run_id: agent_run.id,
            provider: provider,
            error_class: e.class.name,
            error: e.message
          )
        end

        nil
      end

      def draft_decision_record(prompt)
        parsed = send_to_llm(prompt)
        return nil unless parsed

        required_keys = %i[title summary decision]
        return nil unless required_keys.all? { |key| parsed[key].present? }

        parsed
      end

      def chat_providers
        owner = agent_run.project&.effective_owner
        setting = owner&.settings
        providers = setting ? Knowledge::ProviderSelector.for_chat(user_setting: setting) : []

        providers.presence || [ DEFAULT_PROVIDER ]
      end

      def model_for(provider)
        DEFAULT_MODEL if provider == DEFAULT_PROVIDER
      end

      def llm_request_options(provider)
        options = {
          provider: ProviderSupport.harness_provider_key_for(provider).to_sym,
          timeout: TIMEOUT,
          dangerous_mode: false,
          tools: :none
        }
        options[:model] = DEFAULT_MODEL if provider == DEFAULT_PROVIDER
        # Only route through text mode for Claude; other providers are not
        # required to expose HTTP text transport and fall back to CLI.
        options.merge!(Llm::TextMode.options) if provider == DEFAULT_PROVIDER
        options
      end

      def parse_text_output(output)
        return nil if output.blank?

        cleaned = output.gsub(/\A```(?:json)?\s*/, "").gsub(/\s*```\z/, "").strip
        JSON.parse(cleaned, symbolize_names: true)
      rescue JSON::ParserError => e
        Rails.logger.warn(
          message: "knowledge.decisions.draft_parse_failed",
          agent_run_id: agent_run.id,
          error: e.message,
          error_class: e.class.name
        )
        nil
      end

      def parse_response(response)
        if response.respond_to?(:success?) && !response.success?
          log_payload = {
            message: "knowledge.decisions.draft_llm_failed",
            agent_run_id: agent_run.id
          }
          log_payload[:error] = response.error if response.respond_to?(:error) && response.error
          log_payload[:exit_code] = response.exit_code if response.respond_to?(:exit_code) && response.exit_code
          log_payload[:provider] = response.provider if response.respond_to?(:provider) && response.provider
          log_payload[:model] = response.model if response.respond_to?(:model) && response.model
          Rails.logger.warn(log_payload)
          return nil
        end

        output = response.respond_to?(:output) ? response.output : response.to_s
        parse_text_output(output)
      end

      def create_knowledge_run!
        KnowledgeRun.create!(
          project: agent_run.project,
          operation_type: "decision_drafting",
          status: "running"
        )
      end

      def finalize_knowledge_run!(knowledge_run)
        return unless knowledge_run&.persisted?

        knowledge_run.update!(status: "completed") if knowledge_run.active?
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn(
          message: "knowledge.decisions.draft_knowledge_run_finalize_failed",
          knowledge_run_id: knowledge_run.id,
          error: e.message
        )
      end

      def create_decision_record(parsed)
        record = nil

        begin
          DecisionRecord.transaction do
            record = DecisionRecord.create!(
              project: agent_run.project,
              agent_run: agent_run,
              issue: agent_run.issue,
              title: parsed[:title].to_s.truncate(500),
              summary: parsed[:summary].to_s,
              context: parsed[:context].to_s.presence,
              decision: parsed[:decision].to_s,
              consequences: parsed[:consequences].to_s.presence,
              status: "active",
              commit_sha_start: agent_run.base_commit_sha,
              commit_sha_end: agent_run.result_commit_sha,
              tags: Array(parsed[:tags]).map(&:to_s)
            )

            create_links(record)
          end
        rescue ActiveRecord::RecordNotUnique
          # Another concurrent execution created the record for this agent_run.
          # Return the existing record to make this operation idempotent.
          record = DecisionRecord.find_by(agent_run: agent_run)
        end

        record
      end

      def record_llm_output_metric(record)
        LlmOutputMetrics::Record.call(
          project: agent_run.project,
          output_type: "decision_record",
          prompt_slug: PROMPT_SLUG,
          prompt_project: agent_run.project,
          source_type: "DecisionRecord",
          source_id: record.id
        )
      rescue StandardError => e
        Rails.logger.warn(
          message: "llm_output_metrics.record_decision_record_failed",
          decision_record_id: record.id,
          error: e.message
        )
      end

      def create_links(record)
        if agent_run.id.present?
          record.decision_record_links.create!(
            linkable_type: "AgentRun",
            linkable_id: agent_run.id.to_s,
            link_type: "implements"
          )
        end

        if agent_run.issue_id.present?
          record.decision_record_links.create!(
            linkable_type: "Issue",
            linkable_id: agent_run.issue_id.to_s,
            link_type: "implements"
          )
        end
      end
    end
  end
end
