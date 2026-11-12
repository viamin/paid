# frozen_string_literal: true

require "rails_helper"

RSpec.describe CycleAnalyses::OperatorView do
  let(:user) { create(:user) }
  let(:project) { create(:project, account: user.account, created_by: user, owner: "acme", repo: "alpha") }
  let(:issues) { Array.new(3) { create(:issue, project:, github_state: "open") } }
  let(:edges) do
    [
      create_legacy_issue_dependency(issue: issues[0], depends_on_issue: issues[1],
        declaration_source: "issue_comment", declaration_url: "https://github.com/acme/alpha/issues/1#issuecomment-42"),
      create_legacy_issue_dependency(issue: issues[1], depends_on_issue: issues[2]),
      create_legacy_issue_dependency(issue: issues[2], depends_on_issue: issues[0])
    ]
  end
  let(:cycle) { edges && Issues::DependencyCycles.call(account: user.account).sole }
  let(:snapshot) { CycleAnalyses::Snapshot.call(cycle:) }
  let(:removal_edge) { snapshot.fetch("effective_edges").find { |edge| edge["from_issue_id"] == issues[0].id } }
  let(:recommendation) do
    {
      "summary" => "The declaration on issue 1 is obsolete.",
      "candidates" => [ {
        "declaration_changes" => [ { "edge_id" => removal_edge.fetch("id"), "action" => "remove" } ],
        "evidence" => [ "The target issue was closed as a duplicate." ],
        "tradeoffs" => [ "The declaring issue may start earlier." ],
        "missing_or_conflicting_intent" => [],
        "resulting_graph" => {
          "issue_ids" => snapshot.fetch("issues").map { |issue| issue.fetch("id") },
          "edges" => snapshot.fetch("effective_edges")
            .reject { |edge| edge["id"] == removal_edge.fetch("id") }
            .map { |edge| edge.slice("from_issue_id", "to_issue_id") }
        },
        "acyclic" => true
      } ]
    }
  end

  def view_for(run, cycle_record = cycle)
    described_class.new(cycle: cycle_record, run:)
  end

  def completed_run(result_recommendation = recommendation, status: "completed", repair: nil, coverage: nil, error_message: nil)
    create(:agent_run, status:, project:, initiating_user: user, goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      error_message:,
      external_metadata: { CycleAnalyses::METADATA_KEY => snapshot },
      verification_result: {
        CycleAnalyses::RESULT_KEY => { "recommendation" => result_recommendation,
                                       "coverage" => coverage,
                                       "repair" => repair }.compact
      })
  end

  # @spec AUTO-PICK-QUEUE-023
  it "explains the recommendation and the possible GitHub declaration edit before any analysis" do
    status = view_for(nil).status

    expect(status.key).to eq(:no_analysis)
    expect(status.description).to include("Paid recommends one bounded repair analysis")
    expect(status.description).to include("may edit one verified GitHub dependency declaration")
    expect(status.button).to have_attributes(kind: :start_analysis, label: "Analyze cycle (may edit GitHub)")
    expect(status.button.confirm).to include("may edit one verified GitHub dependency declaration")
  end

  # @spec AUTO-PICK-QUEUE-023
  it "offers only a status check while the analysis is queued or running" do
    [ "queued", "running" ].each do |state|
      run = completed_run(status: state)
      status = view_for(run).status

      expect(status.key).to eq(state.to_sym)
      expect(status.button).to be_nil
      expect(status.description).to include("may edit one verified GitHub dependency declaration")
    end
  end

  # @spec AUTO-PICK-QUEUE-023
  it "does not promise a GitHub edit while a requeued pending-sync confirmation run is in flight" do
    [ "queued", "running" ].each do |state|
      run = completed_run(status: state, repair: { "status" => "pending_sync",
        "details" => { "project_id" => project.id, "issue_number" => issues[0].github_number } })
      status = view_for(run).status

      expect(status.key).to eq(state.to_sym)
      expect(status.button).to be_nil
      expect(status.description).to include("does not edit GitHub")
      expect(status.description).not_to include("may edit one verified GitHub dependency declaration")
    end
  end

  # @spec AUTO-PICK-QUEUE-023
  it "names the automatically repaired declaration and keeps confirmation read-only for a pending sync" do
    run = completed_run(repair: { "status" => "pending_sync", "reason" => "awaiting_github_synchronization",
      "changed_edge_ids" => [ removal_edge.fetch("id") ],
      "details" => { "project_id" => project.id, "issue_number" => issues[0].github_number } })
    status = view_for(run).status

    expect(status.key).to eq(:pending_sync)
    expect(status.description).to include("#{project.full_name}##{issues[0].github_number}")
    expect(status.button).to have_attributes(kind: :confirm_repair, label: "Check synchronized repair status (no GitHub edit)")
    expect(status.button.confirm).to include("does not edit GitHub")
  end

  # @spec AUTO-PICK-QUEUE-023
  it "reports a confirmed repair" do
    run = completed_run(repair: { "status" => "resolved", "reason" => "synchronization_confirmed",
      "changed_edge_ids" => [] })

    status = view_for(run).status

    expect(status.key).to eq(:confirmed)
    expect(status.description).to include("acyclic")
    expect(status.button).to be_nil
  end

  # @spec AUTO-PICK-QUEUE-023
  it "gives an ambiguous recommendation its own status and next action" do
    conflicting = recommendation.deep_merge(
      "candidates" => [ recommendation.fetch("candidates").first.merge("missing_or_conflicting_intent" => [ "Owners disagree." ]) ]
    )
    run = completed_run(conflicting, repair: { "status" => "needs_operator_action", "reason" => "not_obvious" })

    status = view_for(run).status

    expect(status.key).to eq(:ambiguous)
    expect(status.next_action).to include("reviewed removal")
    expect(status.button).to be_nil
  end

  # @spec AUTO-PICK-QUEUE-023
  it "distinguishes a stale analysis graph and offers a fresh analysis" do
    run = completed_run
    changed_cycle = cycle.with(occurrence: "#{cycle.occurrence}:changed")

    status = view_for(run, changed_cycle).status

    expect(status.key).to eq(:stale)
    expect(status.next_action).to include("fresh analysis")
    expect(status.button).to have_attributes(kind: :start_analysis, label: "Analyze current cycle (may edit GitHub)")
  end

  # @spec AUTO-PICK-QUEUE-023
  it "distinguishes a failed analysis and offers a retry" do
    run = completed_run(status: "failed", error_message: "provider unavailable")

    status = view_for(run).status

    expect(status.key).to eq(:failed)
    expect(status.description).to include("provider unavailable")
    expect(status.description).to include("cannot confirm whether GitHub changed")
    expect(status.description).not_to include("Nothing on GitHub changed")
    expect(status.next_action).to start_with("Check the live GitHub declaration")
    expect(status.button).to have_attributes(kind: :retry_analysis, label: "Retry analysis (may edit GitHub)")
  end

  # @spec AUTO-PICK-QUEUE-023
  it "does not offer a start action for a stopped repair, because the completed run for this occurrence blocks a duplicate" do
    reason_phrases = {
      "unauthorized" => "authority for every project in this cycle",
      "graph_changed" => "changed before the write",
      "edge_changed" => "changed on GitHub before the write",
      "live_declaration_missing" => "could not find the declaration on live GitHub"
    }
    reason_phrases.each do |reason, phrase|
      run = completed_run(repair: { "status" => "needs_operator_action", "reason" => reason })

      status = view_for(run).status

      expect(status.key).to eq(:stopped)
      expect(status.title).to eq("Automatic repair stopped")
      expect(status.description).to include(phrase)
      expect(status.button).to be_nil
      expect(status.next_action).to include("Edit the declaration on GitHub yourself")
      expect(status.next_action).to include("only after synchronization changes this cycle")
    end
  end

  # @spec AUTO-PICK-QUEUE-023
  it "offers the read-only confirmation only when Start can resume the pending-sync run" do
    resumable = completed_run(repair: { "status" => "pending_sync",
      "details" => { "project_id" => project.id, "issue_number" => issues[0].github_number } })
    expect(view_for(resumable).status.button).to have_attributes(kind: :confirm_repair)

    stale = completed_run(repair: { "status" => "pending_sync",
      "details" => { "project_id" => project.id, "issue_number" => issues[0].github_number } })
    reoccurred = cycle.with(occurrence: "#{cycle.occurrence}:redeclared")
    stale_status = view_for(stale, reoccurred).status
    expect(stale_status.key).to eq(:stale)
    expect(stale_status.button).to have_attributes(kind: :start_analysis)

    failed = completed_run(status: "failed", error_message: "confirmation crashed", repair: { "status" => "pending_sync",
      "details" => { "project_id" => project.id, "issue_number" => issues[0].github_number } })
    failed_status = view_for(failed).status
    expect(failed_status.key).to eq(:failed)
    expect(failed_status.button).to have_attributes(kind: :retry_analysis)
    expect(failed_status.button.confirm).not_to include("does not edit GitHub")
  end

  # @spec AUTO-PICK-QUEUE-023
  it "keeps a cancelled pending-sync repair read-only and waits for synchronization instead of a fresh editing run" do
    run = completed_run(status: "cancelled", repair: { "status" => "pending_sync",
      "details" => { "project_id" => project.id, "issue_number" => issues[0].github_number } })

    status = view_for(run).status

    expect(status.key).to eq(:pending_sync)
    expect(status.title).to eq("Safe repair made, awaiting synchronization")
    expect(status.next_action).to include("Wait for the next GitHub synchronization")
    expect(status.button).to be_nil
  end

  # @spec AUTO-PICK-QUEUE-023
  it "explains unavailable evidence coverage with its own next action" do
    run = completed_run(coverage: { "unavailable_provenance_edge_ids" => [ edges[1].id ],
                                     "unavailable_content_issue_ids" => [ issues[2].id ] })

    warning = view_for(run).evidence_warning

    expect(warning.title).to eq("Some evidence was unavailable")
    expect(warning.description).to include("1 declaration", "no recorded GitHub source")
    expect(warning.description).to include("1 issue", "could not be read")
    expect(warning.next_action).to include("Synchronize")
  end

  # @spec AUTO-PICK-QUEUE-024
  it "renders the recommendation as readable candidate fields naming the source and target declarations" do
    run = completed_run
    view = view_for(run)

    expect(view.render_recommendation?).to be(true)
    expect(view.recommendation_summary).to eq("The declaration on issue 1 is obsolete.")
    candidate = view.candidates.sole
    expect(candidate.expected_result).to include("acyclic")
    change = candidate.changes.sole
    expect(change.action).to eq("remove")
    expect(change.from_ref).to eq("#{project.full_name}##{issues[0].github_number}")
    expect(change.to_ref).to eq("#{project.full_name}##{issues[1].github_number}")
    expect(change.source_description).to include("trusted comment")
    expect(candidate.evidence).to eq([ "The target issue was closed as a duplicate." ])
    expect(candidate.tradeoffs).to eq([ "The declaring issue may start earlier." ])
    expect(candidate.missing_or_conflicting_intent).to be_empty
  end

  # @spec AUTO-PICK-QUEUE-024
  it "offers a manual repair that names the exact declaration and carries a naming confirmation" do
    run = completed_run
    candidate = view_for(run).manual_repair_candidates.sole

    expect(candidate.repair_button_label).to eq(
      "Remove the #{project.full_name}##{issues[1].github_number} dependency from #{project.full_name}##{issues[0].github_number}"
    )
    expect(candidate.repair_confirmation).to include(
      "#{project.full_name}##{issues[0].github_number}", "#{project.full_name}##{issues[1].github_number}", "edits GitHub"
    )
    expect(candidate.before_description).to include("lists #{project.full_name}##{issues[1].github_number} as a dependency")
    expect(candidate.after_description).to include("stops waiting on #{project.full_name}##{issues[1].github_number}")
  end

  # @spec AUTO-PICK-QUEUE-024
  it "does not offer a manual repair for a stale analysis, a pending sync, or a non-removal candidate" do
    stale_run = completed_run
    changed_cycle = cycle.with(occurrence: "#{cycle.occurrence}:changed")
    expect(view_for(stale_run, changed_cycle).render_recommendation?).to be(false)
    expect(view_for(stale_run, changed_cycle).manual_repair_candidates).to be_empty

    pending_run = completed_run(repair: { "status" => "pending_sync",
      "details" => { "project_id" => project.id, "issue_number" => issues[0].github_number } })
    expect(view_for(pending_run).manual_repair_candidates).to be_empty

    run = completed_run(correction_recommendation)
    expect(view_for(run).manual_repair_candidates).to be_empty
    expect(view_for(run).candidates.sole.changes.sole.action).to eq("correct")
  end

  def correction_recommendation
    remaining_edges = snapshot.fetch("effective_edges")
      .reject { |edge| edge["id"] == removal_edge.fetch("id") }
      .map { |edge| edge.slice("from_issue_id", "to_issue_id") }
    recommendation.deep_merge("candidates" => [ {
      "declaration_changes" => [ { "edge_id" => removal_edge.fetch("id"), "action" => "correct",
                                   "replacement" => { "from_issue_id" => issues[0].id, "to_issue_id" => issues[2].id } } ],
      "evidence" => [ "The target moved." ], "tradeoffs" => [ "None." ],
      "missing_or_conflicting_intent" => [],
      "resulting_graph" => { "issue_ids" => snapshot.fetch("issues").map { |issue| issue.fetch("id") },
                             "edges" => remaining_edges + [ { "from_issue_id" => issues[0].id, "to_issue_id" => issues[2].id } ] },
      "acyclic" => true
    } ])
  end

  # @spec AUTO-PICK-QUEUE-024
  it "keeps only raw diagnostics for the collapsed technical detail" do
    run = completed_run(coverage: { "unavailable_provenance_edge_ids" => [ edges[1].id ],
                                     "unavailable_content_issue_ids" => [ issues[2].id ] })

    view = view_for(run)

    expect(view.raw_recommendation_json).to include('"declaration_changes"')
    expect(view.diagnostics).to include("occurrence" => cycle.occurrence, "fingerprint" => cycle.fingerprint, "agent_run_id" => run.id)
  end
end
