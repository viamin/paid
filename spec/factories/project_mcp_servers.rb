# frozen_string_literal: true

FactoryBot.define do
  factory :project_mcp_server do
    project
    mcp_server_definition { association :mcp_server_definition, account: project.account }
  end
end
