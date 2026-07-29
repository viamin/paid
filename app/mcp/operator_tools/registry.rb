# frozen_string_literal: true

module OperatorTools
  module Registry
    TOOL_CLASSES = [
      "OperatorTools::OperatorConsoleInventory",
      "OperatorTools::ListAccounts",
      "OperatorTools::GetAccount",
      "OperatorTools::ListAccountActivityEvents",
      "OperatorTools::GetAccountActivityEvent",
      "OperatorTools::ListAccountMemberships",
      "OperatorTools::GetAccountMembership",
      "OperatorTools::ListPreCommitRequirements",
      "OperatorTools::GetPreCommitRequirement",
      "OperatorTools::ListProjectMemberships",
      "OperatorTools::GetProjectMembership",
      "OperatorTools::ListStyleGuides",
      "OperatorTools::GetStyleGuide",
      "OperatorTools::ListTenantSettings",
      "OperatorTools::GetTenantSetting",
      "OperatorTools::ListUsers",
      "OperatorTools::GetUser",
      "OperatorTools::SuspendAccount",
      "OperatorTools::ReactivateAccount",
      "OperatorTools::DeactivateAccount",
      "OperatorTools::RecompressStyleGuides"
    ].freeze

    class << self
      def dispatch(name:, arguments:, user:, session:)
        tool_class = find(name)
        raise ArgumentError, "Unknown tool: #{name}" unless tool_class
        raise ArgumentError, "Tool arguments must be a JSON object" unless arguments.is_a?(Hash)

        tool_class.new(user:, session:).dispatch(**arguments.symbolize_keys)
      end

      def dispatch_read_only(name:, arguments:, user:, session:)
        tool_class = read_only_tool_classes_for(user:).find { |klass| klass.tool_name == name }
        raise ArgumentError, "Unknown tool: #{name}" unless tool_class
        raise ArgumentError, "Tool arguments must be a JSON object" unless arguments.is_a?(Hash)

        tool_class.new(user:, session:).dispatch(**arguments.symbolize_keys)
      end

      def find(name)
        tool_hash[name]
      end

      def definitions_for(user:)
        definitions_for_classes(available_tool_classes_for(user:))
      end

      def read_only_definitions_for(user:)
        definitions_for_classes(read_only_tool_classes_for(user:))
      end

      def chat_definitions_for(user:, session: nil)
        available_chat_tool_classes_for(user:, session:).map { |klass| chat_definition_for(klass) }
      end

      def write_tool?(name)
        find(name)&.write_operation? ? true : false
      end

      def post_dispatch_confirmation?(name)
        find(name)&.confirmation_mode == :post_dispatch
      end

      def resolve_confirmation(name:, decision:, pending_result:, user:, session:)
        tool_class = find(name)
        raise ArgumentError, "Unknown tool: #{name}" unless tool_class

        tool_class.new(user:, session:).resolve_confirmation(
          decision: decision.to_sym,
          pending_result: pending_result
        )
      end

      def all
        tool_hash.values
      end

      private

      def tool_hash
        @tool_hash ||= TOOL_CLASSES.each_with_object({}) do |class_name, hash|
          klass = class_name.constantize
          hash[klass.tool_name] = klass
        end
      end

      def tool_available_to?(klass, user:)
        return false unless user&.operator?

        klass.available_to?(user:)
      end

      def available_tool_classes_for(user:)
        tool_hash.values.select { |klass| tool_available_to?(klass, user:) }
      end

      def available_chat_tool_classes_for(user:, session:)
        tool_hash.values.select { |klass| klass.available_for_chat?(user:, session:) }
      end

      def read_only_tool_classes_for(user:)
        available_tool_classes_for(user:).reject(&:write_operation?)
      end

      def definitions_for_classes(tool_classes)
        tool_classes.map(&:definition)
      end

      def chat_definition_for(klass)
        return klass.definition unless klass.write_operation?

        definition = klass.definition
        schema = definition[:inputSchema]
        return definition unless schema.is_a?(Hash)

        stripped_schema = schema.deep_dup
        stripped_schema[:properties]&.delete(:confirmed)
        stripped_schema[:required] = Array(stripped_schema[:required]).reject { |field| field.to_s == "confirmed" }

        definition.merge(inputSchema: stripped_schema)
      end
    end
  end
end
