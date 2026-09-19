# frozen_string_literal: true

FactoryBot.define do
  factory :apple_worker_profile do
    account
    created_by { association :user, account: account }
    sequence(:name) { |n| "ios-#{n}" }
    image_digest { "sha256:#{'a' * 64}" }
    capabilities { { "capabilities" => %w[build test launch ui_flow screenshot] } }
    constraints { { "platforms" => [ "ios" ], "xcode_version" => ">= 26.0, < 27.0" } }
  end

  factory :apple_verification_workflow_revision do
    project
    account { project.account }
    apple_worker_profile { association :apple_worker_profile, account: account }
    sequence(:revision)
    content_digest { "sha256:#{'b' * 64}" }
    verification_files { [ { "path" => ".paid/apple-verification.yml", "digest" => "sha256:#{'c' * 64}" } ] }
    lifecycle_gate { "agent_iteration" }
    required_checks { [ "test" ] }
    advisory_checks { [ "screenshot" ] }
  end

  factory :apple_verification_attempt do
    apple_verification_workflow_revision
    project { apple_verification_workflow_revision.project }
    account { apple_verification_workflow_revision.account }
    apple_worker_profile { apple_verification_workflow_revision.apple_worker_profile }
    source_digest { "sha256:#{'d' * 64}" }
    lifecycle_gate { apple_verification_workflow_revision.lifecycle_gate }
  end
end
