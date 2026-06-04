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
        authorized_tool_classes_for(user:).map(&:definition)
      end

      def read_only_definitions_for(user:)
        read_only_tool_classes_for(user:).map(&:definition)
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

      def authorized_tool_classes_for(user:)
        tool_hash.values.select { |klass| tool_available_to?(klass, user:) }
      end

      def read_only_tool_classes_for(user:)
        authorized_tool_classes_for(user:).reject(&:write_operation?)
      end
    end
  end
end
