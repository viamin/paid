# frozen_string_literal: true

FactoryBot.define do
  factory :project_convention_recommendation do
    project
    convention_key { "commit_style" }
    action_type { "apply_in_paid" }
    status { "pending" }
    title { "Enable conventional commit enforcement" }
    description { "Detected conventional commits from commitlint config. Apply enforcement in Paid to ensure consistent commit messages." }
    evidence { { "paths" => [ ".commitlintrc.json" ], "signals" => [ "commitlint" ], "confidence" => 0.95 } }
    generated_at { Time.current }
  end
end
