# frozen_string_literal: true

module Knowledge
  module ContextIntake
    # Loads the business-context question catalog from persisted records.
    # Falls back to bootstrapping a default catalog so the wizard remains
    # operational during rollout and in environments without seeded data.
    module QuestionnaireSchema
      DEFAULT_SECTIONS = [
        {
          key: "product_purpose",
          title: "Product Purpose",
          questions: [
            { key: "product_description", text: "What does this product do and why does it exist?", required: true },
            { key: "business_model", text: "How does the product generate revenue or deliver value?", required: false }
          ]
        },
        {
          key: "target_users",
          title: "Target Users & Markets",
          questions: [
            { key: "primary_users", text: "Who are the primary users or customers? What are the priority audiences?", required: true },
            { key: "non_users", text: "Who is explicitly not the target audience?", required: false }
          ]
        },
        {
          key: "core_workflows",
          title: "Core Workflows",
          questions: [
            { key: "critical_journeys", text: "What are the most important user journeys? What does success look like for each?", required: true },
            { key: "failure_modes", text: "What are known failure modes or edge cases that must be handled carefully?", required: false }
          ]
        },
        {
          key: "feature_semantics",
          title: "Feature Semantics",
          questions: [
            { key: "key_features", text: "What are the key features and what do they mean in business terms?", required: false },
            { key: "good_bad_examples", text: "Can you provide examples of correct vs. incorrect behavior for important features?", required: false }
          ]
        },
        {
          key: "external_docs",
          title: "External Documentation",
          questions: [
            { key: "external_resources", text: "Are there external specs, runbooks, help docs, design docs, or customer-facing docs outside the repository?", required: false },
            { key: "api_contracts", text: "Are there external API contracts, SLAs, or integration agreements that constrain behavior?", required: false }
          ]
        },
        {
          key: "hosting_distribution",
          title: "Hosting & Distribution",
          questions: [
            { key: "deployment_model", text: "How is the product hosted or distributed? (SaaS, on-prem, self-hosted, mobile, desktop, API-only, etc.)", required: true },
            { key: "environments", text: "What environments exist (staging, production, etc.) and what are the promotion rules?", required: false }
          ]
        },
        {
          key: "operational_constraints",
          title: "Operational & Business Constraints",
          questions: [
            { key: "compliance", text: "Are there compliance, regulatory, or legal constraints (GDPR, HIPAA, SOC2, etc.)?", required: false },
            { key: "slas_commitments", text: "What SLAs, pricing commitments, or backwards-compatibility expectations exist?", required: false },
            { key: "migration_constraints", text: "Are there ongoing or planned migrations, deprecations, or breaking changes to be aware of?", required: false }
          ]
        },
        {
          key: "terminology",
          title: "Terminology",
          questions: [
            { key: "domain_terms", text: "What product or domain words have special meanings that differ from their code-level terminology?", required: false },
            { key: "naming_conventions", text: "Are there naming conventions or vocabulary rules that agents should follow in issues and PRs?", required: false }
          ]
        }
      ].freeze

      class << self
        def sections(project: nil)
          ordered_questions(project: project)
            .group_by { |question| [ question[:section_key], question[:section_title] ] }
            .map do |(section_key, section_title), questions|
              {
                key: section_key,
                title: section_title,
                questions: questions.map { |question| question.except(:section_key, :section_title, :section_order) }
              }
            end
        end

        def section_keys(project: nil)
          sections(project: project).map { |section| section[:key] }
        end

        def questions_for_section(section_key, project: nil)
          sections(project: project).find { |section| section[:key] == section_key }&.fetch(:questions, []) || []
        end

        def ordered_questions(project: nil)
          catalog_questions(project: project).map(&:dup)
        end

        def find_question(question_key, project: nil)
          question = question_catalog_index(project: project)[question_key]
          return if question.nil?

          {
            section: { key: question[:section_key], title: question[:section_title] },
            question: question.except(:section_key, :section_title, :section_order)
          }
        end

        def total_questions(project: nil)
          ordered_questions(project: project).size
        end

        def required_questions(project: nil)
          ordered_questions(project: project).select { |question| question[:required] }
        end

        def section_index(section_key, project: nil)
          section_keys(project: project).index(section_key) || 0
        end

        def eligible_questions(project:, round:, responses:)
          ordered_questions(project: project).select do |question|
            question[:round] == round && conditions_match?(question[:conditions], responses)
          end
        end

        def question_for_response(response)
          metadata = question_metadata_for_response(response)
          metadata.merge(
            key: response.question_key,
            text: response.question_text,
            section_key: response.section,
            section_title: metadata[:section_title].presence || response.section.to_s.titleize
          )
        end

        def required_question_for_response?(response, catalog_index: nil)
          question_metadata_for_response(response, catalog_index: catalog_index)[:required] == true
        end

        def question_round_for_response(response, catalog_index: nil)
          question_metadata_for_response(response, catalog_index: catalog_index)[:round] || 1
        end

        def ordered_responses(responses)
          responses_array = Array(responses)
          catalog_index = if (project = project_for_response(responses_array.first))
            question_catalog_index(project: project)
          end

          responses_array.sort_by do |response|
            metadata = question_metadata_for_response(response, catalog_index: catalog_index)
            [
              metadata[:round] || 1,
              metadata[:section_order] || 0,
              metadata[:display_order] || response.sequence || 0,
              response.created_at || Time.at(0),
              response.respond_to?(:id) ? response.id.to_i : 0
            ]
          end
        end

        def question_snapshot(question)
          question.slice(
            :required,
            :category,
            :round,
            :section_order,
            :display_order,
            :section_title,
            :is_follow_up,
            :parent_question_key,
            :conditions,
            :validation_rules,
            :provenance,
            :status,
            :metadata
          )
        end

        def question_catalog_index(project:)
          catalog_questions(project: project).index_by { |question| question[:key] }
        end

        def reset_default_catalog_cache!
          @default_catalog_seeded = false
          @catalog_cache = {}
        end

        private

        def catalog_questions(project:)
          ensure_default_catalog!
          return load_catalog_questions(project: project) if cache_bypass_required?

          @catalog_cache ||= {}
          cache_key = project_cache_key(project)
          @catalog_cache[cache_key] ||= load_catalog_questions(project: project)
        rescue ActiveRecord::NoDatabaseError, ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
          default_questions
        end

        def load_catalog_questions(project:)
          selected = ContextIntakeQuestion.visible_for(project)
                                          .group_by(&:key)
                                          .values
                                          .map { |questions| questions.max_by { |question| [ question.project_id.present? ? 1 : 0, question.id ] } }
                                          .sort_by { |question| [ question.round, question.section_order, question.display_order, question.created_at, question.id ] }

          questions = selected.map(&:to_question_hash)
          questions.presence || default_questions
        end

        def project_cache_key(project)
          return :global if project.nil?

          [ project.id, project.created_at&.utc&.to_f ]
        end

        def default_questions
          DEFAULT_SECTIONS.each_with_index.flat_map do |section, section_index|
            section[:questions].each_with_index.map do |question, question_index|
              {
                key: question[:key],
                text: question[:text],
                required: question[:required],
                section_key: section[:key],
                section_title: section[:title],
                category: section[:key],
                round: 1,
                section_order: section_index,
                display_order: question_index,
                is_follow_up: false,
                parent_question_key: nil,
                conditions: {},
                validation_rules: {},
                provenance: "human",
                status: "approved",
                metadata: {}
              }
            end
          end
        end

        def ensure_default_catalog!
          return if @default_catalog_seeded && !cache_bypass_required?
          return if ContextIntakeQuestion.global_catalog.exists?

          default_questions.each do |question|
            ContextIntakeQuestion.create_or_find_by!(project_id: nil, key: question[:key]) do |record|
              record.question_text = question[:text]
              record.section_key = question[:section_key]
              record.section_title = question[:section_title]
              record.category = question[:category]
              record.round = question[:round]
              record.section_order = question[:section_order]
              record.display_order = question[:display_order]
              record.required = question[:required]
              record.is_follow_up = question[:is_follow_up]
              record.parent_question_key = question[:parent_question_key]
              record.status = question[:status]
              record.provenance = question[:provenance]
              record.active = true
              record.conditions = question[:conditions]
              record.validation_rules = question[:validation_rules]
              record.metadata = question[:metadata]
            end
          end

          @default_catalog_seeded = true unless cache_bypass_required?
        end

        def cache_bypass_required?
          ActiveRecord::Base.connection.transaction_open?
        rescue ActiveRecord::ConnectionNotEstablished
          false
        end

        def question_metadata_for_response(response, catalog_index: nil)
          metadata = response.answer_data.to_h.fetch("question", {}).deep_symbolize_keys
          return metadata if metadata.present?

          project = project_for_response(response)
          fallback_question = (catalog_index || question_catalog_index(project: project))[response.question_key]
          {
            required: fallback_question&.fetch(:required, nil) == true,
            category: response.section,
            round: fallback_question&.fetch(:round, nil) || 1,
            section_order: fallback_question&.fetch(:section_order, nil) || section_index(response.section, project: project),
            display_order: fallback_question&.fetch(:display_order, nil) || response.sequence || 0,
            section_title: fallback_question&.fetch(:section_title, nil) || response.section.to_s.titleize,
            is_follow_up: response.is_follow_up,
            parent_question_key: response.parent_response&.question_key,
            conditions: {},
            validation_rules: {},
            provenance: response.provenance,
            status: "approved",
            metadata: {}
          }
        end

        def project_for_response(response)
          response&.respond_to?(:context_intake_session) ? response.context_intake_session&.project : nil
        end

        def conditions_match?(conditions, responses)
          condition_hash = conditions.to_h.deep_symbolize_keys
          return true if condition_hash.empty?

          target_key = condition_hash[:depends_on_question_key]
          target_response = Array(responses).find { |response| response.question_key == target_key }
          return false if target_key.present? && target_response.nil?

          answer_text = target_response&.answer_text.to_s
          return false if condition_hash[:requires_answer] != false && target_key.present? && answer_text.blank?

          if condition_hash[:minimum_answer_length].present?
            return false if answer_text.length < condition_hash[:minimum_answer_length].to_i
          end

          includes_any = Array(condition_hash[:answer_includes_any]).map(&:to_s).reject(&:blank?)
          if includes_any.any?
            normalized_answer = answer_text.downcase
            return false unless includes_any.any? { |term| normalized_answer.include?(term.downcase) }
          end

          true
        end
      end
    end
  end
end
