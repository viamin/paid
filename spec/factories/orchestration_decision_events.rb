# frozen_string_literal: true

FactoryBot.define do
  factory :orchestration_decision_event do
    project
    issue { create(:issue, project: project) }
    agent_run { create(:agent_run, project: project, issue: issue) }
    decision_point { "manual_retry" }
    action { "retry" }
    status { "applied" }
    signals { { trigger: "manual" } }
    result { { status: "queued" } }
  end
end
