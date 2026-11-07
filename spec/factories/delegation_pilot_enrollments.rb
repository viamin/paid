# frozen_string_literal: true

# @spec PROJECT-DELEGATION-007
FactoryBot.define do
  factory :delegation_pilot_enrollment do
    account { project.account }
    project
    enrolled_by { association :user, account: }
    posture { "bounded_delivery" }
    status { "active" }
    enrolled_at { Time.current }

    trait :paused do
      status { "paused" }
      pause_reason { "missing_evidence" }
      paused_at { Time.current }
      pause_evidence { { "reasons" => [ "missing_metric_evidence" ] } }
    end
  end
end
