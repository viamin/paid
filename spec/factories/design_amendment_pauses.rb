# frozen_string_literal: true

FactoryBot.define do
  factory :design_amendment_pause do
    design_amendment
    issue
    reason_code { "affected" }
    status { "held" }
    evidence { { "cited_claims" => [] } }
  end
end
