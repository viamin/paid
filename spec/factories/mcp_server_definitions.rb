# frozen_string_literal: true

FactoryBot.define do
  factory :mcp_server_definition do
    account
    sequence(:name) { |n| "mcp-server-#{n}" }
    transport { "stdio" }
    install_type { "npx" }
    command { "@modelcontextprotocol/server-filesystem" }
    args { [ "/workspace" ] }
    env { {} }
    enabled { true }
    metadata { {} }

    trait :disabled do
      enabled { false }
    end

    trait :docker do
      install_type { "docker_image" }
      image { "mcp/postgres:latest" }
      command { nil }
    end

    trait :sse do
      transport { "sse" }
      url { "http://localhost:3001/sse" }
    end

    trait :docker_sse do
      transport { "sse" }
      install_type { "docker_image" }
      image { "mcp/web-server:latest" }
      url { "http://localhost:3001/sse" }
      command { nil }
    end
  end
end
