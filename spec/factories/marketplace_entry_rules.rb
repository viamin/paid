# frozen_string_literal: true

FactoryBot.define do
  factory :marketplace_entry_rule do
    marketplace_entry
    mode { "automatic" }
    enabled { true }
    position { 0 }
    rationale { "Apply on Rails implementation runs." }
    conditions { { "goals" => [ "create_pr" ] } }
  end
end
