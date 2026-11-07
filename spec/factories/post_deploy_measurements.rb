# frozen_string_literal: true

# @spec POST-DEPLOY-004
FactoryBot.define do
  factory :post_deploy_measurement do
    account { project.account }
    project
    issue { association :issue, project: }
    check_key { "planning_hold_notifications_actionable" }
    check_version { 1 }
    criterion { "No active agent_planning_hold_reconciliation notification whose source issue is closed remains actionable." }
    status { "pending" }
    deployed_revision { "" }
    attempts { 0 }
    counts { {} }
    details { {} }
  end
end
