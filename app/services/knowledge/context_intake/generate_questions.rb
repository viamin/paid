# frozen_string_literal: true

require "set"

module Knowledge
  module ContextIntake
    class GenerateQuestions
      include Llm::OutputNormalizer

      DEFAULT_MODEL = "claude-sonnet-4-6"
      DEFAULT_PROVIDER = :claude
      TIMEOUT = 60
      MAX_GENERATED_QUESTIONS = 3
      MAX_KEY_ATTEMPTS = 10

      attr_reader :project, :session, :round, :auto_approve

      def initialize(project:, session:, round:, auto_approve: false)
        @project = project
        @session = session
        @round = round
        @auto_approve = auto_approve
      end

      def self.call(...)
        new(...).call
      end

      def call
        response = AgentHarness.send_message(
          build_prompt,
          provider: DEFAULT_PROVIDER,
          model: DEFAULT_MODEL,
          timeout: TIMEOUT,
          dangerous_mode: false,
          tools: :none,
          **Llm::TextMode.options
        )

        return [] unless response.success?

        create_questions(parse_questions(response.output))
      rescue AgentHarness::Error, JSON::ParserError => e
        Rails.logger.warn(
          message: "context_intake.generate_questions_failed",
          project_id: project.id,
          session_id: session.id,
          round: round,
          error_class: e.class.name,
          error: e.message
        )
        []
      end

      private

      def build_prompt
        <<~PROMPT
          You are helping Paid collect higher-signal business context for a software project.

          Generate up to #{MAX_GENERATED_QUESTIONS} follow-up questions for round #{round}.
          Use the project's knowledge base, prior business-context answers, and project metadata.
          Only ask questions that would materially improve future agent execution.
          Prefer targeted follow-ups over broad repeats.

          Return ONLY valid JSON:
          {
            "questions": [
              {
                "key": "optional_stable_key",
                "text": "question text",
                "section_key": "existing_or_new_section_key",
                "section_title": "Human section title",
                "category": "semantic_category",
                "required": false,
                "parent_question_key": "question_being_refined"
              }
            ]
          }

          Project metadata:
          #{JSON.pretty_generate(project_metadata)}

          Prior business-context answers:
          #{JSON.pretty_generate(prior_answers)}

          Related knowledge artifacts:
          #{JSON.pretty_generate(knowledge_artifacts)}
        PROMPT
      end

      def project_metadata
        {
          id: project.id,
          name: project.name,
          repository: project.full_name,
          default_branch: project.default_branch,
          knowledge_status: project.knowledge_status
        }
      end

      def prior_answers
        QuestionnaireSchema.ordered_responses(session.context_intake_responses.answered.to_a).map do |response|
          question = QuestionnaireSchema.question_for_response(response)
          {
            question_key: response.question_key,
            question_text: response.question_text,
            answer_text: response.answer_text,
            section_key: question[:section_key],
            round: question[:round],
            parent_question_key: question[:parent_question_key]
          }
        end
      end

      def knowledge_artifacts
        KnowledgeArtifact.for_project(project)
                         .active
                         .order(created_at: :desc)
                         .limit(5)
                         .map do |artifact|
          {
            identifier: artifact.identifier,
            artifact_type: artifact.artifact_type,
            content: artifact.content.to_s.truncate(1000)
          }
        end
      end

      def parse_questions(raw_output)
        cleaned = raw_output.to_s.strip
        loop do
          previous = cleaned
          cleaned = strip_markdown_fence(cleaned)
          cleaned = strip_surrounding_quotes(cleaned)
          break if cleaned == previous
        end

        parsed = JSON.parse(cleaned)
        Array(parsed["questions"])
          .select { |payload| payload.is_a?(Hash) && payload["text"].is_a?(String) }
          .first(MAX_GENERATED_QUESTIONS)
      end

      def create_questions(question_payloads)
        reserved_keys = existing_question_keys

        question_payloads.filter_map do |payload|
          attrs = normalize_payload(payload)
          next if attrs.nil?

          create_question(attrs, reserved_keys: reserved_keys)
        end
      end

      def normalize_payload(payload)
        return unless payload.is_a?(Hash)

        text = payload["text"].strip
        return if text.blank?

        payload_key = normalized_string(payload["key"])
        parent_question_key = normalized_string(payload["parent_question_key"])
        parent_response = parent_question_key && session.context_intake_responses.find_by(question_key: parent_question_key)
        parent_question = parent_response && QuestionnaireSchema.question_for_response(parent_response)

        section_key = normalized_string(payload["section_key"]) || parent_question&.fetch(:section_key, nil) || "follow_up"
        section_title = normalized_string(payload["section_title"]) || parent_question&.fetch(:section_title, nil) || section_key.titleize
        category = normalized_string(payload["category"]) || section_key

        {
          key_base: payload_key || text.parameterize(separator: "_").truncate(60, omission: ""),
          question_text: text,
          section_key: section_key,
          section_title: section_title,
          category: category,
          round: round,
          section_order: parent_question&.fetch(:section_order, nil) || QuestionnaireSchema.section_index(section_key, project: project),
          display_order: next_display_order(section_key),
          required: payload["required"] == true,
          is_follow_up: true,
          parent_question_key: parent_question_key,
          status: auto_approve ? "approved" : "pending_review",
          provenance: "agent",
          active: true,
          conditions: {},
          validation_rules: {},
          metadata: { "generated_for_session_id" => session.id, "generated_round" => round }
        }
      end

      def create_question(attrs, reserved_keys:)
        key_base = attrs.delete(:key_base)
        attempts = 0

        begin
          project.context_intake_questions.create!(
            attrs.merge(key: unique_key_for(key_base, reserved_keys: reserved_keys))
          )
        rescue ActiveRecord::RecordNotUnique
          attempts += 1
          retry if attempts < MAX_KEY_ATTEMPTS

          raise
        end
      end

      def unique_key_for(base_key, reserved_keys:)
        normalized_base = base_key.presence || "generated_question"
        candidate = normalized_base
        suffix = 1

        while reserved_keys.include?(candidate)
          suffix += 1
          candidate = "#{normalized_base}_#{suffix}"
          raise "Could not generate unique key after #{MAX_KEY_ATTEMPTS} attempts" if suffix > MAX_KEY_ATTEMPTS
        end

        reserved_keys << candidate
        candidate
      end

      def existing_question_keys
        Set.new(
          session.context_intake_responses.distinct.pluck(:question_key) +
          ContextIntakeQuestion.where(project_id: [ nil, project.id ]).distinct.pluck(:key)
        )
      end

      def normalized_string(value)
        stripped = value.is_a?(String) ? value.strip : nil
        stripped.presence
      end

      def next_display_order(section_key)
        project.context_intake_questions.where(round: round, section_key: section_key).maximum(:display_order).to_i + 1
      end
    end
  end
end
