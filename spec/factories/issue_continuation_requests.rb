# frozen_string_literal: true

FactoryBot.define do
  factory :issue_continuation_request do
    issue
    project { issue.project }
    requested_by { association :user, account: issue.project.account }
    reason { "Deliberate continuation requested from the partial-closeout inbox lane." }
    evidence { { "merged_prs" => [] } }
    evidence_digest { Issues::CloseoutEvidence.call(issue).digest }
    status { "queued" }

    trait :consumed do
      status { "consumed" }
      closed_at { Time.current }
      closure_reason { "run terminal status: completed" }
    end

    trait :superseded do
      status { "superseded" }
      closed_at { Time.current }
      closure_reason { "evidence generation changed before dispatch" }
    end
  end
end
