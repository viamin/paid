# frozen_string_literal: true

module IssueTrackers
  module AdapterFactory
    ADAPTERS = {
      "github_issues" => "IssueTrackers::Adapters::GithubIssues",
      "jira" => "IssueTrackers::Adapters::Jira",
      "linear" => "IssueTrackers::Adapters::Linear",
      "azure_devops" => "IssueTrackers::Adapters::AzureDevops",
      "mcp" => "IssueTrackers::Adapters::Mcp",
      "generic_webhook" => "IssueTrackers::Adapters::GenericWebhook"
    }.freeze

    module_function

    def build(tracker_configuration)
      adapter_class = adapter_class_for(tracker_configuration.tracker_type)
      adapter_class.new(tracker_configuration)
    end

    def adapter_class_for(tracker_type)
      class_name = ADAPTERS[tracker_type.to_s]
      raise ArgumentError, "Unknown tracker type: #{tracker_type}" unless class_name

      class_name.constantize
    end
  end
end
