# frozen_string_literal: true

# @spec PROJECT-DELEGATION-002
FactoryBot.define do
  factory :intent_checkpoint do
    account { project.account }
    project
    issue { association :issue, project: }
    status { "pending" }
    groups do
      [
        {
          "key" => "data-retention-policy",
          "affected_scope" => "Data retention policy",
          "questions" => [ "How long must imported metrics be retained?" ],
          "recommendation" => "Retain 30 days of imported metrics.",
          "alternatives" => [ "Retain 7 days" ],
          "consequences" => [ "Longer retention increases storage cost." ],
          "evidence" => [ "docs/intent/data-pipeline/design.md" ]
        }
      ]
    end
    answers { {} }

    trait :settled do
      status { "settled" }
      disposition { "settled" }
      design_revision { "design:#{Digest::SHA256.hexdigest("design")}" }
      acceptance_revision { "criteria:#{Digest::SHA256.hexdigest("criteria")}" }
      settled_by { association :user, account: }
      settled_at { 1.hour.ago }
      answers { { "data-retention-policy" => "Retain 30 days." } }
    end

    trait :rejected do
      status { "rejected" }
      disposition { "rejected" }
      design_revision { "design:#{Digest::SHA256.hexdigest("design")}" }
      acceptance_revision { "criteria:#{Digest::SHA256.hexdigest("criteria")}" }
      settled_by { association :user, account: }
      settled_at { 1.hour.ago }
    end
  end
end
