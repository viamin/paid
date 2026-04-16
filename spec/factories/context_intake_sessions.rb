# frozen_string_literal: true

FactoryBot.define do
  factory :context_intake_session do
    project
    started_by { association :user, account: project.account }
    status { "in_progress" }
    schema_version { "1.0" }
    current_step { 0 }
    metadata { {} }

    trait :completed do
      status { "completed" }
      completed_at { Time.current }
    end

    trait :stale do
      status { "stale" }
      stale_at { Time.current }
    end

    trait :archived do
      status { "archived" }
    end
  end
end
