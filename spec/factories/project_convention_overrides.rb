# frozen_string_literal: true

FactoryBot.define do
  factory :project_convention_override do
    project
    key { "commit_style" }
    value { { "type" => "conventional_commits", "required" => true, "default_type" => "feat" } }
    rationale { "Project-specific override" }
    enabled { true }
  end
end
