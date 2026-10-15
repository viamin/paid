# frozen_string_literal: true

FactoryBot.define do
  factory :design_artifact_finding do
    association :project
    account { project.account }
    sequence(:fingerprint) { |n| Digest::SHA256.hexdigest("finding-#{n}") }
    artifact_path { "docs/rdrs/RDR-063-example.md" }
    revision { "a" * 40 }
    state { "missing_tree" }
    evidence { [ "No explicit qualified issue links were found" ] }
    covered_at { Time.current }
    status { "open" }
  end
end
