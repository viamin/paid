# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

# @spec AUTO-PICK-QUEUE-023 OPERATOR-INBOX-027
RSpec.describe "Cycle repair mobile actions", system_driver: :paid_cuprite, type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:alpha) { create(:project, account:, created_by: user, owner: "acme", repo: "alpha", auto_pick_enabled: true, active: true) }
  let(:beta) { create(:project, account:, created_by: user, owner: "acme", repo: "beta", auto_pick_enabled: true, active: true) }

  before do
    allow(GithubClient).to receive(:new).and_return(instance_double(GithubClient, issue_comments: []))
    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after { Warden.test_reset! }

  it "keeps the exact cross-project declaration label readable in the original and projected actions" do
    cycle = create_cycle_analysis
    [ 320, 390, 768, 1440 ].each do |width|
      page.current_window.resize_to(width, 844)
      visit inbox_entry_path(cycle.id)
      expect(page).to have_text("One declaration needs owner review.")
      expect(page).to have_css('[data-testid="manual-repair"] [type="submit"]')
      expect(page).to have_css('[data-inbox-actions-target="bar"] button', text: /trusted comment/)
      metrics = action_bounds
      expect(metrics).not_to be_empty
      expect(metrics.all? { |control| control.fetch("right") <= width + 1 && control.fetch("scroll") <= control.fetch("client") + 1 }).to be(true)
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth + 1")).to be(true)
    end
  end

  def action_bounds
    page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('[data-inbox-actions-target="bar"] button, [data-testid="manual-repair"] [type="submit"]'))
        .map(control => ({right: control.getBoundingClientRect().right, client: control.clientWidth, scroll: control.scrollWidth}))
    JS
  end

  def create_cycle_analysis
    issues = [ create(:issue, project: alpha), create(:issue, project: beta), create(:issue, project: alpha) ]
    create_legacy_issue_dependency(issue: issues[0], depends_on_issue: issues[1], declaration_source: "issue_comment",
      declaration_url: "https://github.com/acme/alpha/issues/1#issuecomment-42")
    create_legacy_issue_dependency(issue: issues[1], depends_on_issue: issues[2])
    create_legacy_issue_dependency(issue: issues[2], depends_on_issue: issues[0])
    cycle = Issues::DependencyCycles.call(account:).sole
    snapshot = CycleAnalyses::Snapshot.call(cycle:)
    edge = snapshot.fetch("effective_edges").find { |item| item["from_issue_id"] == issues[0].id }
    create(:agent_run, status: "completed", project: alpha, initiating_user: user, goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => snapshot },
      verification_result: { CycleAnalyses::RESULT_KEY => {
        "recommendation" => recommendation(snapshot, edge),
        "coverage" => { "unavailable_provenance_edge_ids" => [], "unavailable_content_issue_ids" => [] },
        "repair" => { "status" => "needs_operator_action", "reason" => "not_obvious" }
      } })
    cycle
  end

  def recommendation(snapshot, edge)
    {
      "summary" => "One declaration needs owner review.", "candidates" => [ {
        "declaration_changes" => [ { "edge_id" => edge.fetch("id"), "action" => "remove" } ],
        "evidence" => [ "Prior link is obsolete." ], "tradeoffs" => [ "The source may proceed earlier." ],
        "missing_or_conflicting_intent" => [ "Confirm the intended ordering." ],
        "resulting_graph" => {
          "issue_ids" => snapshot.fetch("issues").map { |issue| issue.fetch("id") },
          "edges" => snapshot.fetch("effective_edges").reject { |item| item["id"] == edge.fetch("id") }
            .map { |item| item.slice("from_issue_id", "to_issue_id") }
        }, "acyclic" => true
      } ]
    }
  end
end
