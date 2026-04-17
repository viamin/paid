# frozen_string_literal: true

FactoryBot.define do
  factory :prompt_version do
    prompt
    sequence(:version) { |n| n }
    template { "You are working on {{title}}.\n\n{{body}}" }
    variables { [ { "name" => "title", "required" => true }, { "name" => "body", "required" => true } ] }
    created_by { "seed" }

    trait :with_system_prompt do
      system_prompt { "You are a helpful coding assistant." }
    end

    trait :with_parent do
      after(:build) do |version|
        version.parent_version ||= build(:prompt_version, prompt: version.prompt)
      end
    end

    trait :pending_review do
      review_status { "pending" }
      created_by { "evolution" }
    end

    trait :approved do
      review_status { "approved" }
      reviewed_at { Time.current }
    end

    trait :rejected do
      review_status { "rejected" }
      reviewed_at { Time.current }
      review_notes { "Did not meet quality bar" }
    end
  end
end
