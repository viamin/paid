# frozen_string_literal: true

module Automation
  module Providers
    # WorkItemProvider defines the capabilities the automation system needs
    # from a work-item tracker (GitHub Issues, Linear, Jira, ...) for
    # issue-driven orchestration: selecting issues, inspecting dependencies,
    # and transitioning state.
    #
    # "Work item" is intentionally generic. Implementations are expected to
    # map the provider's native concepts (issue, ticket, story, task) onto
    # the {Automation::Providers::Data::Issue} shape, but the policy layer
    # only knows about work items.
    #
    # == Contract
    #
    # Implementations MUST:
    #
    # - Return {Data::Issue} records whose +state+ is one of the enumerated
    #   symbols declared on that class, even if the provider's native state
    #   names differ. Provider-specific state names MAY also be exposed on
    #   the +raw_state+ field for audit purposes.
    # - Populate {Data::Issue#dependencies} with structured dependency
    #   records whenever the provider natively models blockers/dependencies.
    #   Providers without a native dependency model MAY return an empty
    #   array; text-parsed dependencies remain the responsibility of
    #   Paid's {Issues::ParseDependencies} service.
    # - Treat {#transition_state} as the single write-path for lifecycle
    #   changes. Label-based transitions SHOULD route through label
    #   add/remove rather than {#transition_state}.
    #
    # == Method groups
    #
    # * Read: {#fetch_issue}, {#list_issues}, {#fetch_issue_comments},
    #   {#fetch_issue_timeline}
    # * Write: {#create_issue}, {#add_labels}, {#remove_label},
    #   {#add_comment}, {#transition_state}
    module WorkItemProvider
      class ProviderError < StandardError; end

      # Fetches a single work item by its provider-local identifier.
      #
      # @param repo [String] Provider-specific container identifier
      #   (repo slug for GitHub; project key for Jira; team key for
      #   Linear). Providers MUST document the accepted shape.
      # @param number [Integer, String] Work-item identifier. Providers
      #   whose identifiers are not integers (e.g. Linear "ENG-123") MUST
      #   accept String and document the format.
      # @return [Automation::Providers::Data::Issue]
      def fetch_issue(repo:, number:)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      # Lists work items matching the given filters.
      #
      # @param repo [String]
      # @param state [Symbol] One of +:open+, +:closed+, or +:all+.
      # @param labels [Array<String>, nil] Optional label/tag filter.
      # @param assignees [Array<String>, nil] Optional assignee-login
      #   filter. Providers that do not expose assignee identity MAY raise
      #   {ProviderError} rather than silently ignoring the filter.
      # @return [Array<Automation::Providers::Data::Issue>]
      def list_issues(repo:, state: :open, labels: nil, assignees: nil)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      # Fetches conversation comments on a work item.
      #
      # @param repo [String]
      # @param number [Integer, String]
      # @return [Array<Automation::Providers::Data::Comment>]
      def fetch_issue_comments(repo:, number:)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      # Fetches the activity timeline for a work item. Providers with no
      # native timeline SHOULD return synthetic events derived from the
      # state transitions they can observe.
      #
      # @param repo [String]
      # @param number [Integer, String]
      # @return [Array<Automation::Providers::Data::TimelineEvent>]
      def fetch_issue_timeline(repo:, number:)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      # Creates a new work item.
      #
      # @param repo [String]
      # @param title [String]
      # @param body [String]
      # @param labels [Array<String>]
      # @return [Automation::Providers::Data::Issue]
      def create_issue(repo:, title:, body: "", labels: [])
        raise NotImplementedError, not_implemented_message(__method__)
      end

      # Adds labels to a work item.
      #
      # @param repo [String]
      # @param number [Integer, String]
      # @param labels [Array<String>]
      # @return [void]
      def add_labels(repo:, number:, labels:)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      # Removes a label from a work item. No-op when the label is absent.
      #
      # @param repo [String]
      # @param number [Integer, String]
      # @param label [String]
      # @return [void]
      def remove_label(repo:, number:, label:)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      # Posts a comment on a work item.
      #
      # @param repo [String]
      # @param number [Integer, String]
      # @param body [String] Markdown body.
      # @return [Automation::Providers::Data::Comment]
      def add_comment(repo:, number:, body:)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      # Transitions a work item to a new lifecycle state.
      #
      # @param repo [String]
      # @param number [Integer, String]
      # @param state [Symbol] Target state. Must be one of the states
      #   declared on {Automation::Providers::Data::Issue::STATES}.
      #   Providers MAY accept a provider-specific String instead, but MUST
      #   raise {ProviderError} if the requested transition is not legal.
      # @param reason [String, nil] Optional human-readable reason that the
      #   provider SHOULD surface in its audit log.
      # @return [Automation::Providers::Data::Issue] The updated issue.
      def transition_state(repo:, number:, state:, reason: nil)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      private

      def not_implemented_message(method_name)
        "#{self.class} must implement ##{method_name}"
      end
    end
  end
end
