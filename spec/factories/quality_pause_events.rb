# frozen_string_literal: true

FactoryBot.define do
  factory :quality_pause_event do
    project
    event_type { "paused" }
    composite_score { 0.35 }
    threshold { 0.5 }
    metadata { { triggered_at: Time.current.iso8601 } }

    trait :paused do
      event_type { "paused" }
    end

    trait :resumed do
      event_type { "resumed" }
      composite_score { nil }
      threshold { nil }
      metadata { { resumed_at: Time.current.iso8601 } }
    end
  end
end
