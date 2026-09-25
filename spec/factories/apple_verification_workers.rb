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

    trait :approved do
      after(:create) do |workflow|
        administrator = create(:user, account: workflow.account)
        administrator.add_role(:project_admin, workflow.project)
        workflow.approve!(actor: administrator)
      end
    end
  end

  factory :apple_verification_attempt do
    project
    account { project.account }
    apple_verification_workflow_revision { association :apple_verification_workflow_revision, :approved, project:, account: }
    apple_worker_profile { apple_verification_workflow_revision.apple_worker_profile }
    source_digest { "sha256:#{'d' * 64}" }
    lifecycle_gate { apple_verification_workflow_revision.lifecycle_gate }

    trait :committed do
      commit_sha { "0123456789abcdef0123456789abcdef01234567" }
    end

    trait :failed do
      status { "failed" }
      finished_at { Time.current }
    end

    trait :succeeded do
      status { "succeeded" }
      finished_at { Time.current }
    end
  end

  factory :apple_verification_waiver do
    apple_verification_attempt
    account { apple_verification_attempt.account }
    project { apple_verification_attempt.project }
    apple_verification_workflow_revision { apple_verification_attempt.apple_verification_workflow_revision }
    created_by do
      association(:user, account: account).tap { |user| user.add_role(:project_admin, project) }
    end
    source_digest { apple_verification_attempt.source_digest }
    lifecycle_gate { apple_verification_attempt.lifecycle_gate }
    check_ids { apple_verification_attempt.apple_verification_workflow_revision.required_checks }
    reason { "Known simulator outage" }
    expires_at { 1.hour.from_now }
  end
end
