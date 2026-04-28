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
        tools[name]
      end

      def definitions_for(user:, session:)
        tools.values.map(&:definition)
      end

      def all
        tools.values
      end

      private

      def tools
        @tools ||= TOOL_CLASSES.each_with_object({}) do |class_name, hash|
          klass = class_name.constantize
          hash[klass.tool_name] = klass
        end
      end
    end
  end
end
