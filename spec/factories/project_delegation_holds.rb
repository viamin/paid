# frozen_string_literal: true

# @spec PROJECT-DELEGATION-010
FactoryBot.define do
  factory :project_delegation_hold do
    account { project.account }
    project
    held_by { association :user, account: }
    reason { "Waiting for the security review" }
    status { "held" }
    held_at { Time.current }
  end
end
