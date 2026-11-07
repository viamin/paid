# frozen_string_literal: true

# @spec PROJECT-DELEGATION-007
FactoryBot.define do
  factory :delegation_pilot_metric_snapshot do
    account { project.account }
    project
    enrollment { association :delegation_pilot_enrollment, project:, account: }
    posture { "bounded_delivery" }
    window_started_at { 14.days.ago }
    window_ended_at { Time.current }
    metrics { {} }
    exclusions { [] }
    revisions { {} }
  end
end
