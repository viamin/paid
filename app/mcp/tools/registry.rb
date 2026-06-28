# frozen_string_literal: true

module Tools
  module Registry
    TOOL_CLASSES = [
      "Tools::ListProjects",
      "Tools::GetProject",
      "Tools::GetProjectIssues",
      "Tools::GetProjectPullRequests",
      "Tools::TriggerAgentRun",
      "Tools::GetAgentRun",
      "Tools::ListAgentRuns",
      "Tools::CancelAgentRun",
      "Tools::RecordChangeIntent",
      "Tools::GetIssueDetails",
      "Tools::GetPullRequestDetails",
      "Tools::SearchCode",
      "Tools::ReadRepoFile",
      "Tools::ListRepoTree",
      "Tools::GrepRepo",
      "Tools::ListAccountMemberships",
      "Tools::InviteAccountMember",
      "Tools::UpdateAccountMembership",
      "Tools::RemoveAccountMembership",
      "Tools::GetUserSettings",
      "Tools::UpdateUserSettings",
      "Tools::GetTenantSettings",
      "Tools::UpdateTenantSettings",
      "Tools::ListProviderApiKeys",
      "Tools::CreateProviderApiKey",
      "Tools::UpdateProviderApiKey",
      "Tools::RemoveProviderApiKey",
      "Tools::ListMcpServerDefinitions",
      "Tools::CreateMcpServerDefinition",
      "Tools::UpdateMcpServerDefinition",
      "Tools::RemoveMcpServerDefinition"
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

      # Tools advertised to the chat agent loop. Includes write tools so the
      # model can *propose* them, but strips the per-tool `confirmed` argument
      # so confirmation always originates from the human approver, never the
      # model itself. See RDR-028.
      def chat_definitions_for(user:)
        available_tool_classes_for(user:).map { |klass| chat_definition_for(klass) }
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
        klass.available_to?(user:)
      end

      def available_tool_classes_for(user:)
        tool_hash.values.select { |klass| tool_available_to?(klass, user:) }
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
