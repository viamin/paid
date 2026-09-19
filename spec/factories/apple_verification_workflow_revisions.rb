# frozen_string_literal: true

FactoryBot.define do
  factory :apple_verification_workflow_revision do
    project
    profile_name { "ios-app" }
    source_digest { "sha256:workflow" }
    lifecycle_gate { "completion_verification" }
    referenced_files { [ ".paid/apple-verification.yml" ] }

    trait :approved do
      state { "approved" }
    end
  end
end
