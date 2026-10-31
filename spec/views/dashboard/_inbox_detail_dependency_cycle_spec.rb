# frozen_string_literal: true

require "rails_helper"

# @spec AUTO-PICK-QUEUE-024
RSpec.describe "dashboard/_inbox_detail_dependency_cycle", type: :view do
  let(:user) { create(:user) }
  let(:project) { create(:project, account: user.account, created_by: user) }
  let(:first) { create(:issue, project:, github_state: "open") }
  let(:second) { create(:issue, project:, github_state: "open") }
  let(:cycle) do
    create_legacy_issue_dependency(issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    Issues::DependencyCycles.call(account: user.account).sole
  end

  def entry_for(cycle)
    Inbox::Queue::Entry.new(
      id: cycle.id, kind: Inbox::Queue::DEPENDENCY_CYCLE_KIND, project: cycle.project, issue: nil,
      record: cycle, waiting_since: nil, questions: [], tasks: [], summary_text: nil, title_text: nil,
      action_url: nil, guidance: nil, closeout_status: nil
    )
  end

  def render_detail(cycle)
    render partial: "dashboard/inbox_detail_dependency_cycle", locals: { entry: entry_for(cycle) }
    Nokogiri::HTML.fragment(rendered)
  end

  def run_with_repair(status)
    create(:agent_run, :completed, project: cycle.project, initiating_user: user,
      goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => CycleAnalyses::Snapshot.call(cycle:) },
      verification_result: {
        CycleAnalyses::RESULT_KEY => {
          "recommendation" => { "summary" => "x", "candidates" => [] },
          "coverage" => {},
          "repair" => { "status" => status, "applied_changes" => [ first.id ], "message" => "repair message #{status}" }
        }
      })
  end

  it "does not render a view run link once the repair is confirmed" do
    run_with_repair("repaired")

    fragment = render_detail(cycle)

    expect(fragment.text).not_to include("view run")
    expect(fragment.text).to include("repair message repaired")
  end

  %w[not_attempted stale unauthorized provenance_unavailable verification_failed
     declaration_not_isolated write_failed confirmation_unavailable still_cyclic].each do |status|
    it "keeps the view run link for a #{status} repair outcome" do
      run = run_with_repair(status)

      fragment = render_detail(cycle)

      expect(fragment.css("a").map { |a| a["href"] }).to include(
        a_string_matching(%r{/projects/#{cycle.project.id}/agent_runs/#{run.id}\z})
      )
      expect(fragment.text).to include("repair message #{status}")
    end
  end

  it "renders without a repair section when no analysis has run yet" do
    fragment = render_detail(cycle)

    expect(fragment.css("input[type=submit]").map { |input| input["value"] }).to include("Start cycle analysis")
    expect(fragment.text).not_to include("Repair attempt")
  end
end
