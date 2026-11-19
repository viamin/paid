# frozen_string_literal: true

FactoryBot.define do
  factory :design_artifact_association do
    association :project
    account { project.account }
    artifact_path { "docs/rdrs/RDR-063-example.md" }
    artifact_revision { "a" * 40 }
    sequence(:issue_identity) { |n| "#{project.full_name}##{10 + n}" }
    provenance { "canonical issue-tree manifest" }
  end
end
