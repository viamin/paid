# frozen_string_literal: true

FactoryBot.define do
  factory :prompt_version do
    prompt
    sequence(:version) { |n| n }
    template { "You are working on {{title}}.\n\n{{body}}" }
    variables { [{ "name" => "title", "required" => true }, { "name" => "body", "required" => true }] }
    created_by { "seed" }

    trait :with_system_prompt do
      system_prompt { "You are a helpful coding assistant." }
    end

    trait :with_parent do
      parent_version { association :prompt_version, prompt: prompt }
    end
  end
end
