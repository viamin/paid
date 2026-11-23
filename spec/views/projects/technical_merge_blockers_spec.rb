# frozen_string_literal: true

require "rails_helper"

# @spec AUTO-MERGE-012
RSpec.describe "projects/_technical_merge_blockers", type: :view do
  it "separates escaped technical work from approval and links the responsible issue" do
    project = create(:project)
    owner = create(:issue, project:)
    render partial: "projects/technical_merge_blockers", locals: { project:, blockers: [ {
      "reason" => "<script>alert('x')</script>", "release_condition" => "Pass the SDK controls", "owner_issue_number" => owner.github_number
    } ] }
    expect(rendered).to include("Paid or agent action", "Pass the SDK controls", "not a request for human approval")
    expect(rendered).to include(owner.github_url)
    expect(rendered).not_to include("<script>")
  end
end
