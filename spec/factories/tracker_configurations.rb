# frozen_string_literal: true

FactoryBot.define do
  factory :tracker_configuration do
    association :configurable, factory: :account
    tracker_type { "github_issues" }
    enabled { true }

    trait :for_project do
      association :configurable, factory: :project
    end

    trait :for_user do
      association :configurable, factory: :user
    end

    trait :jira do
      tracker_type { "jira" }
      base_url { "https://myorg.atlassian.net" }
      project_mapping { { "project_key" => "PROJ" } }
    end

    trait :linear do
      tracker_type { "linear" }
      project_mapping { { "team_id" => "team-abc-123" } }
    end

    trait :azure_devops do
      tracker_type { "azure_devops" }
      base_url { "https://dev.azure.com/myorg" }
      project_mapping { { "project" => "MyProject" } }
    end

    trait :mcp do
      tracker_type { "mcp" }
      project_mapping { { "mcp_server_definition_id" => 1 } }
    end

    trait :generic_webhook do
      tracker_type { "generic_webhook" }
      base_url { "https://hooks.example.com" }
    end

    trait :disabled do
      enabled { false }
    end

    trait :with_credential do
      integration_credential do
        resolved_account =
          case configurable
          when Account then configurable
          when User then configurable.account
          when Project then configurable.account
          end
        association :integration_credential, :jira, account: resolved_account
      end
    end
  end
end
