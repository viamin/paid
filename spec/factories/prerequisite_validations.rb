# frozen_string_literal: true

FactoryBot.define do
  factory :prerequisite_validation do
    account
    project
    issue
    requested_by { create(:user, account: account) }
    status { "pending" }
    include_tool_sidecar { true }
    scope_digest { "" }
    capability_snapshot { {} }
    blockers { [] }
    result { {} }
  end
end
