# frozen_string_literal: true

FixtureKit.define do
  project = create(:project)
  agent_run = create(:agent_run, :with_custom_prompt, :with_git_context, :with_metrics,
    project: project,
    goal: "create_issue",
    custom_prompt: "Analyze the auth system")

  expose(project:, agent_run:)
end
