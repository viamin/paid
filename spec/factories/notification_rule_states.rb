# frozen_string_literal: true

FactoryBot.define do
  factory :notification_rule_state do
    account
    sequence(:source) { |n| "rule_#{n}" }
    subject { association :issue, project: association(:project, account: account) }
    metadata { {} }
    first_seen_at { Time.current }
    last_seen_at { Time.current }
  end
end
