# frozen_string_literal: true

require "rails_helper"

# @spec STAGED-CLOSEOUT-ADOPTION-013
# Receipts and semantic audits below are
# persisted unit fixtures; no command or real GitHub mutation is performed.
RSpec.describe Issues::AutoResolveCloseout do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, :with_github_installation, account:, created_by: owner, owner: "acme", repo: "staged-fixture") }
  let(:issue) { create(:issue, project:, github_state: "open", body: "## Acceptance\n- Postmerge observation") }
  let(:criterion) { "Postmerge observation" }
  let!(:recipe) { create(:pre_commit_requirement, project:, account:, enabled: true, command: "printf 'unit fixture only'") }
  let(:client) { instance_double(GithubClient) }
  let(:source_pr) do
    create(:issue, :pull_request, project:, parent_issue: issue, github_number: 42,
      github_state: "closed", pr_review_phase: "merged", merged_commit_sha: "a" * 40,
      github_html_url: "https://github.com/acme/staged-fixture/pull/42", body: "Tracks ##{issue.github_number}")
  end
  let(:mapping) do
    StagedCloseoutAdoption::Mappings.approve(project:, actor: owner, issue:, attributes: {
      criterion_key: criterion, stage: "merged_revision", phase: "release_deployment",
      target_shape: "source_pr_merged_revision", execution_path: "technical_prerequisite",
      target_key: recipe.id, freshness_seconds: 60
    })
  end

  before do
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)
    allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(true)
    plan = Configuration::Profiles::Planner.call(profile: Configuration::Profiles::SoloAutomated, project:, actor: owner)
    Configuration::Profiles::Applier.call(plan:, project:, actor: owner)
    ProjectDelegation::SelectPosture.call(project:, actor: owner, level: "bounded_delivery",
      reason: "Explicit isolated acceptance-fixture authority; not an operating policy change")
    allow(client).to receive_messages(issue: Struct.new(:state).new("open"), update_issue: Struct.new(:state).new("closed"))
    source_pr
    create(:agent_run, :completed, project:, issue:, goal: "create_pr", completed_at: 2.hours.ago,
      pull_request_number: source_pr.github_number, pull_request_url: source_pr.github_html_url,
      result_commit_sha: source_pr.merged_commit_sha,
      verification_result: { "status" => "passed", "summary" => "Unit fixture premerge CI; not a postmerge receipt" })
    assessment("unmet")
    mapping
  end

  def assessment(state, criterion_key: criterion)
    request = create(:issue_continuation_request, :consumed, project:, issue:, requested_by: owner,
      evidence: { "continuation_mode" => "acceptance_audit",
        "closeout_policy_signature" => Issues::AutoResolveCloseout.authority_signature(issue),
        "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
        "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue) })
    audit = create(:agent_run, :completed, project:, issue:, goal: "analyze_issue", continuation_request: request,
      pull_request_number: nil, pull_request_url: nil, result_commit_sha: nil)
    audit.update!(reconciliation: { "assessment" => PartialCloseouts::Assessment.snapshot(audit, {
      "criteria" => [ { "criterion" => criterion_key, "state" => state,
        "evidence" => [ { "label" => "Simulated unit audit", "url" => source_pr.github_html_url } ] } ],
      "gaps" => [], "input_coverage" => { "complete" => true, "reasons" => [] }
    }) })
  end

  def receipt(outcome: "passed", target: source_pr.merged_commit_sha)
    create(:agent_run, project:, issue:, agent_type: "internal_agent", goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL,
      synthetic: true, status: outcome == "passed" ? "completed" : "failed", completed_at: Time.current,
      source_pull_request_number: source_pr.github_number, base_commit_sha: target,
      closeout_mapping_id: mapping.id, closeout_criterion_key: mapping.criterion_key,
      closeout_recipe_version: mapping.target_version, closeout_recipe_digest: mapping.target_digest,
      verification_result: { "closeout_verification" => {
        "source_issue_id" => issue.id, "criterion" => mapping.criterion_key, "source_pr_number" => source_pr.github_number,
        "merged_commit_sha" => target, "recipe_version" => mapping.target_version, "recipe_digest" => mapping.target_digest,
        "mapping_id" => mapping.id, "outcome" => outcome, "recorded_at" => Time.current.iso8601,
        "technical_evidence" => { "native" => { "exit_code" => outcome == "passed" ? 0 : 1, "stdout" => "Unit receipt fixture" },
                                  "cleanup" => { "completed" => true } }
      } })
  end

  def current_audit
    issue.agent_runs.where(goal: "analyze_issue").order(:id).last
  end

  def closeout
    return described_class.call(agent_run: current_audit, client:) if closeout_mode == :automatic

    result = Issues::ResolveCloseout.call(issue:, actor: owner, client:,
      reason: "Fixture acceptance audit and current staged receipt establish the declared postmerge criterion.")
    result.success? ? :closed : result.code
  end

  it "retains Tracks at the current-head premerge boundary for an unverified required stage" do
    source_pr.update!(github_state: "open", pr_review_phase: "draft", merged_commit_sha: nil)
    assessment("satisfied")
    snapshot = current_audit.reconciliation.fetch("assessment")
    result = PartialCloseouts::SourceClosureDisposition.for_pull_request(issue:, assessment: snapshot,
      head_sha: "a" * 40, verification_revision: snapshot.fetch("verification_revision"))

    expect(result.fetch("disposition")).to eq("track")
    expect(source_pr.reload.body).to eq("Tracks ##{issue.github_number}")
  end

  shared_examples "staged acceptance gate" do
    it "has a positive control with a current successful mapped receipt and audit" do
      receipt
      assessment("satisfied")

      expect(closeout).to eq(:closed)
      expect(client).to have_received(:update_issue).once
    end

    it "does not close from a current positive audit when its required postmerge receipt is missing" do
      assessment("satisfied")

      expect(closeout).not_to eq(:closed)
      expect(issue.reload.github_state).to eq("open")
      expect(client).not_to have_received(:update_issue)
    end

    it "does not close from a current positive audit over a stale target receipt" do
      receipt(target: "b" * 40)
      assessment("satisfied")

      expect(closeout).not_to eq(:closed)
      expect(issue.reload.github_state).to eq("open")
      expect(client).not_to have_received(:update_issue)
    end

    it "does not close from a current positive audit over a failed required check" do
      receipt(outcome: "failed")
      assessment("satisfied")

      expect(closeout).not_to eq(:closed)
      expect(issue.reload.github_state).to eq("open")
      expect(client).not_to have_received(:update_issue)
    end

    it "does not close when a fresh optimistic audit cites an already expired receipt" do
      run = receipt
      run.update!(completed_at: 2.minutes.ago)
      assessment("satisfied")

      expect(closeout).not_to eq(:closed)
      expect(client).not_to have_received(:update_issue)
    end

    it "invalidates an accepted audit on clock-only receipt expiry" do
      receipt
      assessment("satisfied")
      travel 61.seconds do
        expect(closeout).not_to eq(:closed)
        expect(client).not_to have_received(:update_issue)
      end
    end

    it "does not close from check success without a satisfying semantic audit" do
      receipt
      assessment("unmet")

      expect(closeout).not_to eq(:closed)
      expect(client).not_to have_received(:update_issue)
    end

    it "does not let an optimistic audit omit a currently reviewed required criterion" do
      receipt
      assessment("satisfied")
      audit = current_audit
      audit.update!(reconciliation: { "assessment" => PartialCloseouts::Assessment.snapshot(audit, {
        "criteria" => [ { "criterion" => "An unrelated criterion", "state" => "satisfied",
          "evidence" => [ { "label" => "Simulated incomplete criterion enumeration" } ] } ],
        "gaps" => [], "input_coverage" => { "complete" => true, "reasons" => [] }
      }) })
      expect(closeout).not_to eq(:closed)
      expect(client).not_to have_received(:update_issue)
    end

    it "does not impose a historical removed criterion on newly assessed changed intent" do
      receipt
      issue.update!(body: "## Acceptance\n- A replacement criterion")
      assessment("satisfied", criterion_key: "A replacement criterion")
      expect(closeout).to eq(:closed)
      expect(client).to have_received(:update_issue).once
    end

    it "keeps omitted verification history incomplete despite a newly optimistic audit" do
      8.times { |index| receipt(target: format("%040x", index + 1)) }
      receipt
      assessment("satisfied")
      expect(closeout).not_to eq(:closed)
      expect(client).not_to have_received(:update_issue)
    end

    it "does not accept a revoked required mapping after an optimistic audit" do
      receipt
      StagedCloseoutAdoption::Mappings.revoke(mapping:, project:, actor: owner, issue:, attributes: {})
      assessment("satisfied")
      expect(closeout).not_to eq(:closed)
      expect(client).not_to have_received(:update_issue)
    end

    it "does not accept a receipt with incomplete bounded output" do
      run = receipt
      result = run.verification_result.deep_dup
      result["closeout_verification"]["technical_evidence"]["native"]["stdout"] = "x" * (CloseoutVerifications::Evidence::MAX_NATIVE_OUTPUT_BYTES + 1)
      run.update!(verification_result: result)
      assessment("satisfied")
      expect(closeout).not_to eq(:closed)
      expect(client).not_to have_received(:update_issue)
    end

    # @spec PARTIAL-CLOSEOUT-057 STAGED-CLOSEOUT-ADOPTION-013
    it "accepts complete native output above the independent measurement bound" do
      run = receipt
      result = run.verification_result.deep_dup
      result["closeout_verification"]["technical_evidence"]["native"].merge!(
        "stdout" => "x" * 8_000, "output_truncated" => false)
      run.update!(verification_result: result)
      assessment("satisfied")

      expect(closeout).to eq(:closed)
      expect(client).to have_received(:update_issue).once
    end

    # @spec PARTIAL-CLOSEOUT-057 STAGED-CLOSEOUT-ADOPTION-013
    it "rejects capture clipping even when retained output fits the packet" do
      run = receipt
      result = run.verification_result.deep_dup
      result["closeout_verification"]["technical_evidence"]["native"].merge!(
        "stdout" => "x" * 1_999, "output_truncated" => true)
      run.update!(verification_result: result)
      assessment("satisfied")

      expect(closeout).not_to eq(:closed)
      expect(client).not_to have_received(:update_issue)
    end

    it "requires actual native success and cleanup even when a receipt labels itself passed" do
      run = receipt
      result = run.verification_result.deep_dup
      result["closeout_verification"]["technical_evidence"]["cleanup"]["completed"] = false
      run.update!(verification_result: result)
      assessment("satisfied")
      expect(closeout).not_to eq(:closed)
      expect(client).not_to have_received(:update_issue)
    end

    it "rechecks freshness after the GitHub read before writing closure" do
      receipt
      assessment("satisfied")
      allow(client).to receive(:issue) do
        travel 61.seconds
        Struct.new(:state).new("open")
      end
      expect(closeout).not_to eq(:closed)
      expect(client).not_to have_received(:update_issue)
    ensure
      travel_back
    end
  end

  context "with delegated closure" do
    let(:closeout_mode) { :automatic }

    it_behaves_like "staged acceptance gate"
  end

  context "with explicit closure" do
    let(:closeout_mode) { :explicit }

    it_behaves_like "staged acceptance gate"
  end
end
