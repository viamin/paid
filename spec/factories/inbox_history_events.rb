FactoryBot.define do
  factory :inbox_history_event do
    association :account
    project { create(:project, account:) }
    subject_key { "issue:#{project.id}:42" }
    sequence(:event_key) { |number| "event:#{number}" }
    occurred_at { Time.current }
    actor_label { "Paid" }
    source { "paid" }
    result { "completed" }
    metadata { {} }
  end
end
