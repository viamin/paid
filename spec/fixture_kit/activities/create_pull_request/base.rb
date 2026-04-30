# frozen_string_literal: true

FixtureKit.define do
  project = create(:project)
  issue = create(:issue, project: project)
  agent_run = create(:agent_run, :with_git_context, :with_metrics, project: project, issue: issue)

  expose(project:, issue:, agent_run:)
end
