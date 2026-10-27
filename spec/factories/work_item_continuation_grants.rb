# frozen_string_literal: true

# @spec AUTOMATION-PHASES-005 @spec AUTOMATION-PHASES-008 @spec AUTOMATION-PHASES-019
FactoryBot.define do
  factory :work_item_continuation_grant do
    project
    issue { association :issue, project: }
    start_phase { Automation::Phases::CODING }
    endpoint { Automation::Phases::MERGE }
    source { "manual_start" }
    created_by { association :user, account: project.account }
  end
end
