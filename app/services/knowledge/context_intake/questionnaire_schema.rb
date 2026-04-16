# frozen_string_literal: true

module Knowledge
  module ContextIntake
    # Defines the predefined business-context questionnaire structure.
    # Each section contains a set of questions with keys, display text,
    # and whether they are required for session completion.
    module QuestionnaireSchema
      SECTIONS = [
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

      def self.sections
        SECTIONS
      end

      def self.section_keys
        SECTIONS.map { |s| s[:key] }
      end

      def self.questions_for_section(section_key)
        section = SECTIONS.find { |s| s[:key] == section_key }
        section&.dig(:questions) || []
      end

      def self.find_question(question_key)
        SECTIONS.each do |section|
          question = section[:questions].find { |q| q[:key] == question_key }
          return { section: section, question: question } if question
        end
        nil
      end

      def self.total_questions
        SECTIONS.sum { |s| s[:questions].size }
      end

      def self.required_questions
        SECTIONS.flat_map { |s| s[:questions].select { |q| q[:required] } }
      end

      def self.section_index(section_key)
        SECTIONS.index { |s| s[:key] == section_key } || 0
      end
    end
  end
end
