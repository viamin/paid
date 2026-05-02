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
      "Tools::SearchCode"
    ].freeze

    class << self
      def find(name)
        tool_hash[name]
      end

      def definitions_for(user:)
        tool_hash.values.select { |klass| tool_available_to?(klass, user:) }.map(&:definition)
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
        return true unless klass.write_operation?

        return true if Pundit.policy(user, Project.new(account: user.account))&.run_agent?

        scope = Pundit.policy_scope!(user, Project)

        scope.any? { |project| Pundit.policy!(user, project).run_agent? }
      end
    end
  end
end
