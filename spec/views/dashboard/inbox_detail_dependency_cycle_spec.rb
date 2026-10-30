# frozen_string_literal: true

require "rails_helper"

# @spec AUTO-PICK-QUEUE-016
# Renders the dependency-cycle detail partial against a real
# Issues::DependencyCycles result so the shown context is asserted on locally
# synced data end to end.
RSpec.describe "dashboard/inbox_detail_dependency_cycle", type: :view do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user, owner: "acme", repo: "widgets") }
  let(:umbrella) do
    create(:issue, project:, github_state: "open", github_number: 9,
      title: "Widget factory migration umbrella")
  end

  def build_cycle(path_issues)
    create(:issue_dependency, issue: path_issues.first, depends_on_issue: path_issues.second,
      declaration_source: "issue_comment",
      declaration_url: "https://github.com/acme/widgets/issues/#{path_issues.first.github_number}#issuecomment-7")
    create_legacy_issue_dependency(issue: path_issues.second, depends_on_issue: path_issues.first)

    cycle = Issues::DependencyCycles.call(account: account).sole
    Inbox::Queue::Entry.new(id: cycle.id, kind: Inbox::Queue::DEPENDENCY_CYCLE_KIND, project: cycle.project,
      issue: nil, record: cycle, waiting_since: cycle.detected_at, questions: [], tasks: [],
      summary_text: cycle.summary, title_text: cycle.title, action_url: nil)
  end

  def cycle_entry
    first = create(:issue, project:, github_state: "open", github_number: 41,
      title: "Migrate the widget factory", labels: [ "P1", "epic" ], parent_issue: umbrella)
    second = create(:issue, project:, github_state: "open", github_number: 42,
      title: "Remove the legacy widget gauge")
    build_cycle([ first, second ])
  end

  def render_fragment(entry)
    render partial: "dashboard/inbox_detail_dependency_cycle", locals: { entry: entry }
    Nokogiri::HTML.fragment(rendered)
  end

  it "shows each path issue's linked repository reference, number, and synced title" do
    fragment = render_fragment(cycle_entry)

    refs = fragment.css("[data-testid='dependency-cycle-node-ref']")
    expect(refs.map(&:text)).to contain_exactly("acme/widgets#41", "acme/widgets#42")
    expect(refs.map { |ref| ref["href"] }).to contain_exactly(
      "https://github.com/acme/widgets/issues/41", "https://github.com/acme/widgets/issues/42"
    )
    expect(fragment.css("[data-testid='dependency-cycle-node-title']").map(&:text))
      .to contain_exactly("Migrate the widget factory", "Remove the legacy widget gauge")
  end

  it "keeps the full title available on hover and keyboard focus via the focusable issue link" do
    fragment = render_fragment(cycle_entry)

    ref = fragment.css("[data-testid='dependency-cycle-node-ref']").find { |node| node.text.include?("#41") }
    expect(ref["title"]).to eq("acme/widgets#41 — Migrate the widget factory")
    expect(ref["target"]).to eq("_blank")
    expect(ref["rel"]).to include("noopener", "noreferrer")
  end

  it "shows each path issue's synced labels" do
    fragment = render_fragment(cycle_entry)

    labeled = fragment.css("[data-testid='dependency-cycle-labels']")
    expect(labeled.size).to eq(1)
    expect(labeled.sole.css("[data-testid='dependency-cycle-label']").map { |chip| chip.text.strip })
      .to contain_exactly("P1", "epic")
  end

  it "links the umbrella parent number and title when the path issue has one" do
    fragment = render_fragment(cycle_entry)

    umbrellas = fragment.css("[data-testid='dependency-cycle-umbrella']")
    expect(umbrellas.size).to eq(1)
    expect(umbrellas.sole.text).to include("acme/widgets#9", "Widget factory migration umbrella")
    umbrella_link = umbrellas.sole.css("a").sole
    expect(umbrella_link["href"]).to eq("https://github.com/acme/widgets/issues/9")
    expect(umbrella_link["title"]).to eq("acme/widgets#9 — Widget factory migration umbrella")
  end

  it "keeps long titles and label lists readable on narrow screens" do
    long_title = "Rewrite the widget factory gauge calibration pass so the migration can proceed without flakes"
    first = create(:issue, project:, github_state: "open", github_number: 43, title: long_title,
      labels: [ "P1", "epic", "needs-design", "blocked", "long-running-migration-effort" ], parent_issue: umbrella)
    second = create(:issue, project:, github_state: "open", github_number: 44, title: "Second")
    fragment = render_fragment(build_cycle([ first, second ]))

    expect(fragment.css("[data-testid='dependency-cycle-node-title']").map { |node| node["class"] })
      .to all(include("truncate"))
    label_list = fragment.css("[data-testid='dependency-cycle-labels']").sole
    expect(label_list["class"]).to include("flex-wrap")
    chips = label_list.css("[data-testid='dependency-cycle-label']")
    expect(chips.map { |chip| chip.text.strip }).to include("long-running-migration-effort")
    expect(chips.map { |chip| chip["title"] }).to include("long-running-migration-effort")
  end

  it "keeps declaration provenance adjacent to each dependent → prerequisite edge" do
    fragment = render_fragment(cycle_entry)

    declarations = fragment.css("[data-testid='dependency-cycle-declaration']")
    expect(declarations.size).to eq(2)

    provenance = declarations.find { |node| node.css("a").any? }
    expect(provenance.text).to include("acme/widgets#41", "acme/widgets#42", "declares")
    expect(provenance.css("a").sole.text).to eq("view declaring comment")
    expect(provenance.css("a").sole["href"]).to eq("https://github.com/acme/widgets/issues/41#issuecomment-7")

    fallback = declarations.find { |node| node.text.include?("declaration source unavailable") }
    expect(fallback.text).to include("acme/widgets#42", "acme/widgets#41")
    expect(fallback.css("a")).to be_empty
  end

  it "shows the downstream held count" do
    first = create(:issue, project:, github_state: "open", github_number: 41, title: "Migrate the widget factory")
    second = create(:issue, project:, github_state: "open", github_number: 42, title: "Remove the legacy widget gauge")
    downstream = create(:issue, project:, github_state: "open", github_number: 45)
    downstream.issue_dependencies.create!(depends_on_issue: first)
    fragment = render_fragment(build_cycle([ first, second ]))

    expect(fragment.css("[data-testid='dependency-cycle-downstream']").text).to include("1 downstream open issue")
  end
end
