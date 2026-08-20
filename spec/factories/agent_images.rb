# frozen_string_literal: true

FactoryBot.define do
  factory :agent_image do
    account
    sequence(:name) { |n| "image_#{n}" }
    tag { "latest" }
    registry { "docker.io" }
    repository { "paid-agent" }
    sequence(:digest) { |n| "sha256:" + format("%064d", n) }
    architecture { "amd64" }
    built_at { Time.current }
    status { "active" }
    provenance { { "git_sha" => "abc123", "build_url" => "https://example.test/builds/1" } }
    metadata { { "build_log_url" => "https://example.test/builds/1/log" } }

    trait :deprecated do
      status { "deprecated" }
      deprecated_at { Time.current }
      deprecation_reason { "superseded by a newer build" }
    end

    trait :blocked do
      status { "blocked" }
      blocked_at { Time.current }
      blocked_reason { "CVE-2026-9999 in base image" }
    end

    trait :arm64 do
      architecture { "arm64" }
    end

    trait :production do
      name { "base" }
      tag { "latest" }
      repository { "paid-agent" }
    end
  end
end
