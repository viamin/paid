# frozen_string_literal: true

FactoryBot.define do
  factory :external_connector_event do
    project
    account { project.account }
    connector_key { "jira" }
    event_type { "issue_created" }
    external_event_id { "evt-#{SecureRandom.uuid}" }
    payload { {} }
    normalized_data { {} }
    status { "pending" }

    trait :processed do
      status { "processed" }
      processed_at { Time.current }
    end

    trait :failed do
      status { "failed" }
      processed_at { Time.current }
    end
  end
end
