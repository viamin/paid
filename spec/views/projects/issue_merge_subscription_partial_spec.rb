# frozen_string_literal: true

require "rails_helper"

RSpec.describe "projects/_issue_merge_subscription", type: :view do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }

  it "renders a lazy-loaded frame when no subscription state is provided" do
    render partial: "projects/issue_merge_subscription", locals: { project: project, issue: issue }

    expect(rendered).to include(%(id="#{dom_id(issue, :merge_subscription)}"))
    expect(rendered).to include(%(src="#{project_issue_merge_subscription_path(project, issue)}"))
    expect(rendered).to include("Loading alerts...")
  end
end
