# frozen_string_literal: true

FactoryBot.define do
  factory :project_version do
    project
    sequence(:commit_sha) { |n| Digest::SHA1.hexdigest("commit-#{n}") }
    branch { "main" }
    metadata { {} }
  end
end
