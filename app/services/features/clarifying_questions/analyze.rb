# frozen_string_literal: true

require "json"

module Features
  module ClarifyingQuestions
    # Uses the model for the semantic decision about whether a feature brief is
    # ready. Ruby only validates the returned shape and carries the result into
    # the established needs-input lifecycle.
    # @spec FEATURE-CREATION-001 @spec FEATURE-CREATION-002 @spec FEATURE-CREATION-008
    class Analyze
      DEFAULT_MODEL = "claude-sonnet-4-6"
      TIMEOUT = 60
      MAX_CONTEXT_RESULTS = 8
      MAX_QUESTION_COUNT = 5

      Result = Data.define(:ready, :questions, :feature_brief) do
        def ready? = ready
      end

      class InvalidResponse < StandardError; end

      PROMPT = <<~PROMPT
        You assess whether a proposed software feature has enough settled
        product intent to write a design RDR. Use the supplied feature brief,
        admitted conversation, and repository context together.

        Do not ask for facts that are already stated or that repository context
        answers. Ask only unresolved product, scope, or intent questions. Each
        question must stand alone and state the context that makes the answer
        necessary. Do not use a generic questionnaire or ask questions merely
        because a JSON field is absent.

        Return exactly one JSON object:
        {
          "ready": true or false,
          "questions": ["..."],
          "feature_brief": { "title": "...", "problem": "...", ... }
        }

        Set ready to true only when the supplied intent is sufficient to begin
        RDR research. Then questions must be empty. Set ready to false only
        when one or more targeted questions are necessary; provide at most five.
        Preserve all settled intent in feature_brief and incorporate admitted
        answers. For problem framing, retain evidence references as supplied
        material and retain unresolved assumptions as hypotheses; set
        selected_framing_confirmed to true only when the user confirmed the
        current selected framing. Do not add facts or evidence unsupported by
        the supplied material.

        ## Feature brief
        %{feature_brief}

        ## Admitted conversation
        %{conversation}

        ## Repository context
        %{repository_context}
      PROMPT

      def self.call(...)
        new(...).call
      end

      def initialize(project:, issue:, feature_brief:, agent_run: nil)
        @project = project
        @issue = issue
        @feature_brief = feature_brief.to_h.deep_stringify_keys
        @agent_run = agent_run
      end

      def call
        response = AgentHarness.send_message(
          prompt,
          provider: :claude,
          model: DEFAULT_MODEL,
          timeout: TIMEOUT,
          tools: :none,
          **Llm::TextMode.options
        )
        raise InvalidResponse, "feature clarification analysis failed: #{response.error}" unless response.success?

        result_from(response.output)
      rescue AgentHarness::Error => e
        raise InvalidResponse, "feature clarification analysis failed: #{e.message}"
      end

      private

      attr_reader :project, :issue, :feature_brief, :agent_run

      def prompt
        format(
          PROMPT,
          feature_brief: JSON.pretty_generate(feature_brief),
          conversation: conversation.presence || "(no admitted comments)",
          repository_context: repository_context.presence || "(no matching repository knowledge available)"
        )
      end

      def conversation
        admitted_comments.map { |comment| "- #{comment.user.login}: #{comment.body.to_s.truncate(2_000)}" }.join("\n")
      end

      def admitted_comments
        return [] unless project.client

        project.client.issue_comments(project.full_name, issue.github_number).select do |comment|
          ::ClarifyingQuestions::CommentAdmission.admissible?(project: project, comment: comment)
        end
      rescue GithubClient::Error
        []
      end

      def repository_context
        results = Knowledge::Search.call(
          project: project,
          query: [ issue.title, feature_brief["problem"] ].compact.join("\n").truncate(4_000),
          mode: "semantic",
          limit: MAX_CONTEXT_RESULTS,
          agent_run_id: agent_run&.id
        ).fetch(:results)
        results.map { |result| "- #{result[:title]}: #{result[:content].to_s.truncate(2_000)}" }.join("\n")
      end

      def result_from(output)
        payload = JSON.parse(strip_markdown_fence(output.to_s.strip))
        raise InvalidResponse, "feature clarification analysis must return an object" unless payload.is_a?(Hash)

        ready = payload["ready"]
        raise InvalidResponse, "feature clarification ready must be boolean" unless [ true, false ].include?(ready)

        questions = Array(payload["questions"]).map { |question| question.to_s.strip }.reject(&:blank?)
        raise InvalidResponse, "ready feature clarification must not include questions" if ready && questions.any?
        raise InvalidResponse, "incomplete feature clarification requires questions" if !ready && questions.empty?
        raise InvalidResponse, "feature clarification returned too many questions" if questions.size > MAX_QUESTION_COUNT

        brief = payload["feature_brief"]
        raise InvalidResponse, "feature clarification must return a feature_brief object" unless brief.is_a?(Hash)

        Result.new(ready:, questions:, feature_brief: feature_brief.deep_merge(brief.deep_stringify_keys))
      rescue JSON::ParserError
        raise InvalidResponse, "feature clarification analysis returned invalid JSON"
      end

      def strip_markdown_fence(text)
        text.sub(/\A```(?:json)?\s*/i, "").sub(/\s*```\z/, "")
      end
    end
  end
end
