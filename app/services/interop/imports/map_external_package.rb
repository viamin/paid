# frozen_string_literal: true

module Interop
  module Imports
    class MapExternalPackage
      Result = Struct.new(:source_system, :prompts, :style_guides, :workflow_policies, keyword_init: true)

      SOURCE_MAPPERS = {
        "github_copilot" => :map_copilot,
        "cursor" => :map_cursor,
        "devin" => :map_devin,
        "factory" => :map_factory,
        "internal_agent_workflows" => :map_internal
      }.freeze
      POLICY_TYPE_ALIASES = {
        "review" => "execution",
        "lifecycle" => "lifecycle_state"
      }.freeze

      def self.call(...)
        new(...).call
      end

      def initialize(source_system:, raw_data:)
        @source_system = source_system.to_s
        @raw_data = raw_data.to_h.deep_symbolize_keys
      end

      def call
        mapper = SOURCE_MAPPERS[source_system]
        raise ArgumentError, "no mapper registered for source: #{source_system}" unless mapper

        Result.new(
          source_system: source_system,
          **send(mapper, raw_data)
        )
      end

      private

      attr_reader :source_system, :raw_data

      def map_copilot(data)
        {
          prompts: Array(data[:prompts]).map { |p| map_prompt_entry(p, "copilot") },
          style_guides: [],
          workflow_policies: Array(data[:workflow_policies]).map { |w| map_workflow_entry(w) }
        }
      end

      def map_cursor(data)
        {
          prompts: Array(data[:prompts]).map { |p| map_prompt_entry(p, "cursor") },
          style_guides: Array(data[:style_guides]).map { |g| map_style_guide_entry(g) },
          workflow_policies: Array(data[:workflow_policies]).map { |w| map_workflow_entry(w) }
        }
      end

      def map_devin(data)
        {
          prompts: Array(data[:prompts]).map { |p| map_prompt_entry(p, "devin") },
          style_guides: [],
          workflow_policies: Array(data[:workflow_policies] || data[:workflows]).map { |w| map_workflow_entry(w) }
        }
      end

      def map_factory(data)
        {
          prompts: Array(data[:prompts]).map { |p| map_prompt_entry(p, "factory") },
          style_guides: [],
          workflow_policies: Array(data[:workflow_policies] || data[:policies]).map { |w| map_workflow_entry(w) }
        }
      end

      def map_internal(data)
        {
          prompts: Array(data[:prompts]).map { |p| map_prompt_entry(p, "internal") },
          style_guides: Array(data[:style_guides]).map { |g| map_style_guide_entry(g) },
          workflow_policies: Array(data[:workflow_policies] || data[:policies]).map { |w| map_workflow_entry(w) }
        }
      end

      def map_prompt_entry(entry, prefix)
        {
          slug: entry[:slug].presence || "#{prefix}.#{entry[:name].to_s.parameterize(separator: ".")}",
          name: entry[:name],
          category: entry[:category].presence || "coding",
          description: entry[:description],
          template: entry[:template] || entry[:content] || "",
          system_prompt: entry[:system_prompt],
          variables: Array(entry[:variables]),
          active: entry[:active].nil? ? true : entry[:active]
        }
      end

      def map_style_guide_entry(entry)
        {
          name: entry[:name],
          raw_content: entry[:raw_content] || entry[:content] || "",
          language: entry[:language],
          active: entry[:active].nil? ? true : entry[:active]
        }
      end

      def map_workflow_entry(entry)
        {
          policy_key: entry[:policy_key] || entry[:key] || "",
          policy_type: normalize_policy_type(entry[:policy_type] || entry[:type]),
          name: entry[:name],
          rules: entry[:rules] || {},
          parameters: entry[:parameters] || {},
          context_selector: entry[:context_selector] || {},
          metadata: entry[:metadata] || {}
        }
      end

      def normalize_policy_type(raw_type)
        normalized = raw_type.to_s.presence || "execution"
        normalized = POLICY_TYPE_ALIASES.fetch(normalized.underscore, normalized.underscore)
        return normalized if CoordinationPolicy::POLICY_TYPES.include?(normalized)

        raise ArgumentError, "unsupported policy_type for import: #{raw_type}"
      end
    end
  end
end
