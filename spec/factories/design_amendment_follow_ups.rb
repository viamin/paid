# frozen_string_literal: true

FactoryBot.define do
  factory :design_amendment_follow_up do
    design_amendment
    issue
    status { "open" }
    evidence { { "cited_claims" => [] } }
  end
end
