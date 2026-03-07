# frozen_string_literal: true

FactoryBot.define do
  factory :style_guide do
    sequence(:name) { |n| "Style Guide #{n}" }
    raw_content { "# Ruby Style Guide\n\n- Use snake_case for methods\n- Use CamelCase for classes" }
    active { true }

    trait :global do
      account { nil }
      project { nil }
    end

    trait :for_account do
      account { association :account, strategy: :create }
      project { nil }
    end

    trait :for_project do
      project { association :project, strategy: :create }
      account { project.account }
    end

    trait :inactive do
      active { false }
    end

    trait :with_language do
      language { "ruby" }
    end

    trait :compressed do
      compressed_content { "- snake_case for methods\n- CamelCase for classes" }
      compression_metadata do
        {
          "compressed_at" => Time.current.iso8601,
          "raw_length" => 80,
          "compressed_length" => 48,
          "compression_ratio" => 0.6
        }
      end
    end
  end
end
