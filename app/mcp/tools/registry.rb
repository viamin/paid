# frozen_string_literal: true

module Tools
  module Registry
    TOOL_CLASSES = [
      "Tools::ListProjects",
      "Tools::GetProject",
      "Tools::GetProjectIssues",
      "Tools::GetProjectPullRequests",
      "Tools::UpdateProjectSettings",
      "Tools::TriggerAgentRun",
      "Tools::GetAgentRun",
      "Tools::ListAgentRuns",
      "Tools::CancelAgentRun",
      "Tools::RecordChangeIntent",
      "Tools::GetIssueDetails",
      "Tools::GetPullRequestDetails",
      "Tools::SearchCode",
      "Tools::SearchIntents",
      "Tools::ReadRepoFile",
      "Tools::ListRepoTree",
      "Tools::GrepRepo",
      "Tools::WriteRepoFile",
      "Tools::ApplyPatch",
      "Tools::GitDiff",
      "Tools::GitStatus",
      "Tools::GitBranchCreate",
      "Tools::GetIntent",
      "Tools::ListAccountMemberships",
      "Tools::InviteAccountMember",
      "Tools::UpdateAccountMembership",
      "Tools::RemoveAccountMembership",
      "Tools::GetUserSettings",
      "Tools::UpdateUserSettings",
      "Tools::GetTenantSettings",
      "Tools::UpdateTenantSettings",
      "Tools::ListConfigurationProfiles",
      "Tools::PlanConfigurationProfile",
      "Tools::ApplyConfigurationProfile",
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
      def tools_for(session:, user:)
        available_chat_tool_classes_for(user:, session:) +
          operator_chat_tool_classes_for(user:, session:)
      end

      def dispatch(name:, arguments:, user:, session:)
        dispatch_via_registry(
          registry_for(name),
          name:,
          arguments:,
          user:,
          session:
        )
      end

      def dispatch_read_only(name:, arguments:, user:, session:)
        tool_class = read_only_tool_classes_for(user:).find { |klass| klass.tool_name == name }
        raise ArgumentError, "Unknown tool: #{name}" unless tool_class
        raise ArgumentError, "Tool arguments must be a JSON object" unless arguments.is_a?(Hash)

        tool_class.new(user:, session:).dispatch(**arguments.symbolize_keys)
      end

      def find(name)
        tool_hash[name] || OperatorTools::Registry.find(name)
      end

      def definitions_for(user:)
        definitions_for_classes(available_tool_classes_for(user:)) +
          OperatorTools::Registry.definitions_for(user:)
      end

      def read_only_definitions_for(user:)
        definitions_for_classes(read_only_tool_classes_for(user:)) +
          OperatorTools::Registry.read_only_definitions_for(user:)
      end

      def mcp_definitions_for(user:, session: nil)
        read_only_tools_for(session:, user:).map do |klass|
          mcp_definition_for(klass, session:)
        end
      end

      # Tools advertised to the chat agent loop. Includes write tools so the
      # model can *propose* them, but strips the per-tool `confirmed` argument
      # so confirmation always originates from the human approver, never the
      # model itself. See RDR-028.
      def chat_definitions_for(user:, session: nil)
        tools_for(session:, user:).map { |klass| chat_definition_for(klass) }
      end

      def dispatch_mcp(name:, arguments:, user:, session:)
        ensure_mcp_container_ready(name:, session:)
        return mcp_container_unavailable(name:, session:) if container_tool_unready?(name:, session:)

        dispatch_via_registry(
          registry_for(name),
          name:,
          arguments:,
          user:,
          session:,
          mcp: true
        )
      end

      def write_tool?(name)
        find(name)&.write_operation? ? true : false
      end

      def requires_container?(name)
        find(name)&.requires_container? ? true : false
      end

      def post_dispatch_confirmation?(name)
        find(name)&.confirmation_mode == :post_dispatch
      end

      def resolve_confirmation(name:, decision:, pending_result:, user:, session:)
        registry = registry_for(name)
        raise ArgumentError, "Unknown tool: #{name}" unless registry

        registry.resolve_confirmation(name:, decision:, pending_result:, user:, session:)
      end

      def all
        tool_hash.values + OperatorTools::Registry.all
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

      def available_chat_tool_classes_for(user:, session:)
        tool_hash.values.select { |klass| klass.available_for_chat?(user:, session:) }
      end

      def operator_chat_tool_classes_for(user:, session:)
        OperatorTools::Registry.all.select { |klass| klass.available_for_chat?(user:, session:) }
      end

      def read_only_tool_classes_for(user:)
        available_tool_classes_for(user:).reject(&:write_operation?)
      end

      def read_only_tools_for(session:, user:)
        tools_for(session:, user:).reject(&:write_operation?)
      end

      def definitions_for_classes(tool_classes)
        tool_classes.map(&:definition)
      end

      def mcp_definition_for(klass, session:)
        definition = klass.definition
        return definition unless mcp_container_unavailable_definition?(klass:, session:)

        definition.merge(
          annotations: {
            temporaryUnavailable: true,
            availability: {
              type: "container_capability",
              state: session.container_capability,
              retryable: session.container_capability.in?(%w[pending provisioning]),
              message: Containers::CapabilityMessages.unavailable_for(session.container_capability),
              expectedBehavior: mcp_expected_behavior(session.container_capability)
            }
          }
        )
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

      def registry_for(name)
        return self if tool_hash.key?(name)
        return OperatorTools::Registry if OperatorTools::Registry.find(name)

        nil
      end

      def dispatch_via_registry(registry, name:, arguments:, user:, session:, mcp: false)
        raise ArgumentError, "Unknown tool: #{name}" unless registry

        if mcp
          return dispatch_own_read_only(name:, arguments:, user:, session:) if registry == self

          return registry.dispatch_read_only(name:, arguments:, user:, session:)
        end

        registry == self ? dispatch_own(name:, arguments:, user:, session:) : registry.dispatch(name:, arguments:, user:, session:)
      end

      def dispatch_own(name:, arguments:, user:, session:)
        tool_class = tool_hash[name]
        raise ArgumentError, "Unknown tool: #{name}" unless tool_class
        raise ArgumentError, "Tool arguments must be a JSON object" unless arguments.is_a?(Hash)

        tool_class.new(user:, session:).dispatch(**arguments.symbolize_keys)
      end

      def dispatch_own_read_only(name:, arguments:, user:, session:)
        tool_class = read_only_tools_for(session:, user:).find { |klass| klass.tool_name == name }
        raise ArgumentError, "Unknown tool: #{name}" unless tool_class
        raise ArgumentError, "Tool arguments must be a JSON object" unless arguments.is_a?(Hash)

        tool_class.new(user:, session:).dispatch(**arguments.symbolize_keys)
      end

      def container_tool_unready?(name:, session:)
        requires_container?(name) && !session&.container_ready?
      end

      # Provisions the workspace container when this request wins the
      # none/stopped -> pending transition. When a container is already
      # pending/provisioning the request returns promptly instead of blocking
      # the synchronous MCP tools/call worker; the client retries the call
      # after the tools/list_changed notification emitted on the
      # provisioning -> ready transition (see HandleCapabilityTransition).
      def ensure_mcp_container_ready(name:, session:)
        return unless requires_container?(name)
        return unless session

        provision_mcp_container(session:) if won_container_provision_request?(session)
      end

      # Returns true only when this request won the none/stopped -> pending
      # transition. When a concurrent request already moved the session out of
      # none/stopped, request_container_provision! returns false and the caller
      # returns a retryable unavailable result instead of racing the in-flight
      # provisioning.
      def won_container_provision_request?(session)
        return false unless session.inline_only? || session.container_stopped?

        session.request_container_provision!
      end

      def provision_mcp_container(session:)
        Containers::ProvisionForChat.call(chat_session: session)
        session.reload
      rescue StandardError => error
        log_mcp_container_provision_failure(session:, error:)
        session.reload
      end

      def log_mcp_container_provision_failure(session:, error:)
        Rails.logger.warn(
          message: "mcp.tool_container_provision_failed",
          chat_session_id: session.id,
          error: error.message,
          error_class: error.class.name
        )
      end

      def mcp_container_unavailable_definition?(klass:, session:)
        klass.requires_container? && !session&.container_ready?
      end

      def mcp_container_unavailable(name:, session:)
        capability = session&.container_capability || "none"

        {
          status: "error",
          error: "container_unavailable",
          message: Containers::CapabilityMessages.unavailable_for(capability),
          container_capability: capability,
          retryable: capability.in?(%w[pending provisioning])
        }
      end

      def mcp_expected_behavior(capability)
        case capability
        when "none", "stopped"
          "invoking_triggers_lazy_provisioning"
        when "pending", "provisioning"
          "invoking_returns_retryable_unavailable"
        else
          "invoking_returns_container_unavailable"
        end
      end
    end
  end
end
