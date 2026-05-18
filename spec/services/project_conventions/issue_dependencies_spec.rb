# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectConventions::IssueDependencies do
  let(:first_project) { create(:project) }
  let(:second_project) { create(:project) }

  it "resolves dependency wording per call instead of reusing stale process state" do
    create(:project_convention_override,
      project: first_project,
      key: "issue_dependency_format",
      value: {
        "depends_on_prefix" => "Requires",
        "blocked_by_prefix" => "Awaits",
        "heading" => "## Blockers"
      })
    create(:project_convention_override,
      project: second_project,
      key: "issue_dependency_format",
      value: {
        "depends_on_prefix" => "Depends on",
        "blocked_by_prefix" => "Blocked by",
        "heading" => "## Dependencies"
      })

    expect(described_class.depends_on_line(project: first_project, github_number: 12)).to eq("Requires #12")
    expect(described_class.depends_on_line(project: second_project, github_number: 34)).to eq("Depends on #34")
    expect(described_class.heading(project: first_project)).to eq("## Blockers")
    expect(described_class.heading(project: second_project)).to eq("## Dependencies")
  end
end
