# frozen_string_literal: true

module Interop
  module Imports
    class ApplyProjectPackage
      Result = Struct.new(:prompts_count, :style_guides_count, :workflow_policies_count, keyword_init: true)

      def self.call(...)
        new(...).call
      end

      def initialize(project:, source_system:, prompts: [], style_guides: [], workflow_policies: [])
        @project = project
        @source_system = source_system.to_s
        @prompts = Array(prompts)
        @style_guides = Array(style_guides)
        @workflow_policies = Array(workflow_policies)
      end

      def call
        result = nil

        Project.transaction do
          result = Result.new(
            prompts_count: import_prompts,
            style_guides_count: import_style_guides,
            workflow_policies_count: import_workflow_policies
          )

          persist_import_summary!(result)
        end

        result
      end

      private

      attr_reader :project, :source_system, :prompts, :style_guides, :workflow_policies

      def import_prompts
        prompts.count do |entry|
          data = entry.to_h.deep_symbolize_keys
          prompt = project.prompts.find_or_initialize_by(slug: data.fetch(:slug))
          prompt.account ||= project.account
          prompt.name = data.fetch(:name)
          prompt.category = data.fetch(:category)
          prompt.description = data[:description]
          prompt.active = data.fetch(:active, true)
          prompt.save!

          upsert_prompt_version!(prompt, data)
          true
        end
      end

      def upsert_prompt_version!(prompt, data)
        variables = Array(data[:variables])
        current = prompt.current_version

        return if current &&
          current.template == data.fetch(:template) &&
          current.system_prompt == data[:system_prompt] &&
          current.variables == variables

        prompt.create_version!(
          template: data.fetch(:template),
          system_prompt: data[:system_prompt],
          variables: variables,
          change_notes: "Imported from #{source_system}"
        )
      end

      def import_style_guides
        style_guides.count do |entry|
          data = entry.to_h.deep_symbolize_keys
          guide = project.style_guides.find_or_initialize_by(name: data.fetch(:name))
          guide.account ||= project.account
          guide.raw_content = data.fetch(:raw_content)
          guide.language = data[:language]
          guide.active = data.fetch(:active, true)
          guide.save!
          true
        end
      end

      def import_workflow_policies
        workflow_policies.count do |entry|
          data = entry.to_h.deep_symbolize_keys
          policy = project.coordination_policies.find_or_initialize_by(
            policy_key: data.fetch(:policy_key),
            policy_type: data.fetch(:policy_type)
          )
          policy.account ||= project.account
          policy.name = data.fetch(:name)
          policy.status = policy.current_version&.status == "active" ? "active" : "draft"
          policy.context_selector = data[:context_selector] || {}
          policy.metadata = data[:metadata] || {}
          policy.save!

          version = policy.current_version
          if version.nil? || version.rules != (data[:rules] || {}) || version.parameters != (data[:parameters] || {})
            version = policy.create_version!(
              rules: data[:rules] || {},
              parameters: data[:parameters] || {},
              metadata: {
                "import" => {
                  "source_system" => source_system
                }
              }
            )
            policy.activate_version!(version)
          end

          true
        end
      end

      def persist_import_summary!(result)
        settings = project.effective_interop_settings.deep_dup
        imports = settings.fetch("imports", {})
        summary = {
          "source_system" => source_system,
          "imported_at" => Time.current.iso8601,
          "counts" => {
            "prompts" => result.prompts_count,
            "style_guides" => result.style_guides_count,
            "workflow_policies" => result.workflow_policies_count
          }
        }

        imports["last_import"] = summary
        project.update!(interop_settings: settings.merge("imports" => imports))
      end
    end
  end
end
