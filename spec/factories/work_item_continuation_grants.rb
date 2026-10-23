# frozen_string_literal: true

# @spec AUTOMATION-PHASES-005 @spec AUTOMATION-PHASES-008
FactoryBot.define do
  factory :work_item_continuation_grant do
    project
    issue
    start_phase { Automation::Phases::CODING }
    endpoint { Automation::Phases::MERGE }
    source { "manual_start" }
    created_by { association :user, account: project.account }
  end
end