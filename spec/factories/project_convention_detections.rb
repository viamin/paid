# frozen_string_literal: true

FactoryBot.define do
  factory :project_convention_detection do
    project
    project_version { association :project_version, project: project }
    key { "commit_style" }
    detector_key { "project_conventions" }
    confidence { 1.0 }
    value { { "type" => "conventional_commits", "required" => true, "default_type" => "feat" } }
    evidence { { "paths" => [ "release-please-config.json" ], "signals" => [ "release_please" ] } }
    detected_at { Time.current }
  end
end
