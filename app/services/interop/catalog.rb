# frozen_string_literal: true

module Interop
  module Catalog
    TOOL_INTEGRATIONS = {
      "github_copilot" => "GitHub Copilot",
      "cursor" => "Cursor",
      "devin" => "Devin",
      "factory" => "Factory",
      "internal_agent_workflows" => "Internal Agent Workflows"
    }.freeze

    CONNECTORS = {
      "jira" => "Jira",
      "linear" => "Linear",
      "gitlab" => "GitLab",
      "bitbucket" => "Bitbucket",
      "slack" => "Slack",
      "teams" => "Microsoft Teams",
      "ci_systems" => "CI Systems"
    }.freeze

    EXTERNAL_EXECUTION_SOURCES = TOOL_INTEGRATIONS.freeze

    IMPORT_TYPES = {
      "prompts" => "Prompts",
      "style_guides" => "Style Guides",
      "workflow_policies" => "Workflow Policies"
    }.freeze

    module_function

    def tool_integration_keys
      TOOL_INTEGRATIONS.keys
    end

    def connector_keys
      CONNECTORS.keys
    end

    def external_execution_source_keys
      EXTERNAL_EXECUTION_SOURCES.keys
    end

    def import_keys
      IMPORT_TYPES.keys
    end
  end
end
