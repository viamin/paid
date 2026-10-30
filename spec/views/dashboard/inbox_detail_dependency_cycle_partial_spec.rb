# frozen_string_literal: true

require "rails_helper"

# @spec AUTO-PICK-QUEUE-015 AUTO-PICK-QUEUE-016
RSpec.describe "dashboard/_inbox_detail_dependency_cycle", type: :view do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: owner, owner: "acme", repo: "widgets") }

  def render_detail(cycle)
    entry = Inbox::Queue::Entry.new(
      id: cycle.id,
      kind: Inbox::Queue::DEPENDENCY_CYCLE_KIND,
      project: cycle.project,
      issue: nil,
      record: cycle,
      waiting_since: cycle.detected_at,
      questions: [],
      tasks: [],
      summary_text: cycle.summary,
      title_text: cycle.title,
      action_url: nil
    )
    render partial: "dashboard/inbox_detail_dependency_cycle", locals: { entry: }
    Nokogiri::HTML.fragment(rendered)
  end

  def build_cycle(first:, second:)
    create(:issue_dependency, issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    Issues::DependencyCycles.call(account: account).sole
  end

  # @spec AUTO-PICK-QUEUE-016
  it "shows each path issue's full title on hover and keyboard focus, truncated for narrow screens" do
    long_title = "A" * 200
    first = create(:issue, project:, github_state: "open", title: long_title)
    second = create(:issue, project:, github_state: "open")

    document = render_detail(build_cycle(first:, second:))

    title_node = document.css("p[title]").find { |node| node["title"] == long_title }
    expect(title_node).to be_present
    expect(title_node["class"]).to include("truncate")
    expect(title_node["tabindex"]).to eq("0")
    expect(title_node.text).to eq(long_title)
  end

  # @spec AUTO-PICK-QUEUE-016
  it "shows each path issue's labels and linked repository and number" do
    first = create(:issue, project:, github_state: "open", labels: [ "bug", "P1" ])
    second = create(:issue, project:, github_state: "open")

    document = render_detail(build_cycle(first:, second:))

    expect(document.at_css("a[href='#{first.github_url}']").text).to eq("acme/widgets##{first.github_number}")
    expect(document.text).to include("bug")
    expect(document.text).to include("P1")
  end

  # @spec AUTO-PICK-QUEUE-016
  it "shows a path issue's linked umbrella number and title when it has a parent" do
    parent = create(:issue, project:, title: "Ship the widget umbrella", github_number: 100)
    first = create(:issue, project:, github_state: "open", parent_issue: parent)
    second = create(:issue, project:, github_state: "open")

    document = render_detail(build_cycle(first:, second:))

    umbrella_link = document.at_css("a[href='#{parent.github_url}']")
    expect(umbrella_link.text).to eq("acme/widgets##{parent.github_number}")
    expect(document.text).to include("Ship the widget umbrella")
    expect(document.text).to include("Part of umbrella")
  end

  # @spec AUTO-PICK-QUEUE-016
  it "omits umbrella context for a path issue with no parent" do
    first = create(:issue, project:, github_state: "open")
    second = create(:issue, project:, github_state: "open")

    document = render_detail(build_cycle(first:, second:))

    expect(document.text).not_to include("Part of umbrella")
  end

  # @spec AUTO-PICK-QUEUE-016
  it "shows each path issue's own repository for a cross-project cycle" do
    other_project = create(:project, account:, created_by: owner, owner: "acme", repo: "gadgets")
    first = create(:issue, project:, github_state: "open")
    second = create(:issue, project: other_project, github_state: "open")

    document = render_detail(build_cycle(first:, second:))

    expect(document.at_css("a[href='#{first.github_url}']").text).to eq("acme/widgets##{first.github_number}")
    expect(document.at_css("a[href='#{second.github_url}']").text).to eq("acme/gadgets##{second.github_number}")
  end

  # @spec AUTO-PICK-QUEUE-015
  it "keeps declaration provenance adjacent to each edge, falling back to inspection guidance when unavailable" do
    first = create(:issue, project:, github_state: "open")
    second = create(:issue, project:, github_state: "open")
    declaration_url = "https://github.com/acme/widgets/issues/#{first.github_number}"
    create(:issue_dependency, issue: first, depends_on_issue: second,
      declaration_source: "issue_body", declaration_url: declaration_url)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)

    document = render_detail(Issues::DependencyCycles.call(account: account).sole)

    expect(document.at_css("a[href='#{declaration_url}']")).to be_present
    expect(document.text).to include("declaration source unavailable")
  end
end
