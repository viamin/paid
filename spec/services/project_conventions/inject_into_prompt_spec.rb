# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectConventions::InjectIntoPrompt do
  let(:project) { create(:project) }

  def configure_release_sensitive_conventions(project)
    create(:project_convention_detection,
      project: project,
      key: "pr_title_style",
      value: {
        "type" => "conventional_commits",
        "required" => true,
        "default_type" => "feat",
        "significant_for_release" => true
      })
    create(:project_convention_override,
      project: project,
      key: "issue_dependency_format",
      value: {
        "depends_on_prefix" => "Requires",
        "blocked_by_prefix" => "Awaits",
        "heading" => "## Blockers"
      })
  end

  it "appends convention guidance for repository automation artifacts" do
    configure_release_sensitive_conventions(project)

    prompt = described_class.call(prompt: "Implement the issue.", project: project)

    expect(prompt).to include("## Repository Automation Conventions")
    expect(prompt).to include("PR titles: Required. Use conventional commits")
    expect(prompt).to include("Merged PR titles affect release automation")
    expect(prompt).to include("`Requires #123`")
    expect(prompt).to include("`Awaits owner/repo#123`")
  end

  it "does not append the section more than once" do
    prompt = described_class.call(
      prompt: "Implement the issue.\n\n## Repository Automation Conventions\n\nExisting guidance.",
      project: project
    )

    expect(prompt.scan("## Repository Automation Conventions").size).to eq(1)
  end
end
