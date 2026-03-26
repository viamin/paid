# frozen_string_literal: true

FactoryBot.define do
  factory :collector_run do
    project_version

    collector_type { "ast_grep_routes" }
    status { "completed" }
    metadata { {} }
  end
end
