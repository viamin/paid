# frozen_string_literal: true

module Knowledge
  module Decisions
    # Drafts a decision record from a completed agent run.
    #
    # Summarizes the agent run's changes and calls agent-harness to generate
    # a structured decision record, then stores it as a DecisionRecord with
    # links to the agent run, issue, and a KnowledgeArtifact for search.
    #
    # @example
    #   Knowledge::Decisions::Draft.call(agent_run: agent_run)
    class Draft
      TIMEOUT = 30
      DEFAULT_MODEL = "claude-sonnet-4-6"

      DRAFT_PROMPT = <<~PROMPT
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
        Issue: %{issue_title}
        PR Changes Summary:
        %{changes_summary}
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
        response = send_to_llm(prompt)
        parsed = parse_response(response)
        return nil unless parsed

        # Guard against malformed LLM output missing required fields.
        required_keys = %i[title summary decision]
        return nil unless required_keys.all? { |key| parsed[key].present? }

        create_decision_record(parsed)
      rescue AgentHarness::Error, ActiveRecord::RecordInvalid => e
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
        format(
          DRAFT_PROMPT,
          issue_title: agent_run.issue&.title || "N/A",
          changes_summary: changes_summary.truncate(10_000)
        )
      end

      def send_to_llm(prompt)
        AgentHarness.send_message(
          prompt,
          provider: :claude,
          model: DEFAULT_MODEL,
          timeout: TIMEOUT,
          dangerous_mode: false
        )
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
        return nil if output.blank?

        # Strip markdown fences if present
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
