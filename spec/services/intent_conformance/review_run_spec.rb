# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-REVIEW-001
# @spec INTENT-CONFORMANCE-REVIEW-002
# @spec INTENT-CONFORMANCE-REVIEW-003
# @spec INTENT-CONFORMANCE-REVIEW-004
# @spec INTENT-CONFORMANCE-REVIEW-005
# @spec INTENT-CONFORMANCE-REVIEW-006
# @spec INTENT-CONFORMANCE-REVIEW-007
RSpec.describe IntentConformance::ReviewRun do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :pull_request, project: project, github_number: 42, github_creator_login: "viamin") }
  let(:feature_intent) do
    create(:feature_intent,
      project: project,
      status: "released",
      approved_design_revision: "rev1",
      design_document_paths: [ "docs/rdrs/RDR-999-example.md" ])
  end
  let(:pr_head_sha) { "head_current" }
  let(:github_client) { instance_double(GithubClient) }
  let(:pr_base) { double("pr_base", sha: "base_sha") } # rubocop:disable RSpec/VerifiedDoubles
  let(:pr_data) { double("pr_data", base: pr_base) } # rubocop:disable RSpec/VerifiedDoubles
  let(:comparison) do
    {
      files: [
        { filename: "app/models/widget.rb", status: "modified", additions: 3, deletions: 1, patch: "@@ -1,2 +1,3 @@\n widget code" }
      ]
    }
  end

  def call
    described_class.call(project: project, issue: issue, pr_head_sha: pr_head_sha)
  end

  def response_double(output:, success: true, model: "claude-sonnet-4-6")
    instance_double(AgentHarness::Response, success?: success, output: output, model: model)
  end

  before do
    project.account.tenant_setting!.update!(features: { "approved_intent_amendments" => true })
    create(:feature_intent_issue, feature_intent: feature_intent, issue: issue)
    allow(project).to receive(:client).and_return(github_client)
    allow(project).to receive_messages(full_name: "acme/widgets", client: github_client)
    allow(github_client).to receive(:file_content)
      .with("acme/widgets", path: "docs/rdrs/RDR-999-example.md", ref: "rev1")
      .and_return("# RDR-999\n\nThe widget SHALL always be blue.")
    allow(github_client).to receive(:pull_request).with("acme/widgets", 42).and_return(pr_data)
    allow(github_client).to receive(:compare_summary).with("acme/widgets", "base_sha", pr_head_sha).and_return(comparison)
  end

  # @spec INTENT-CONFORMANCE-REVIEW-001
  context "when the issue is not linked to a feature intent" do
    let(:issue) { create(:issue, :pull_request, project: project) }

    before { FeatureIntentIssue.delete_all }

    it "is a no-op and persists nothing" do
      expect(call).to be_nil
      expect(IntentConformanceVerdict.count).to eq(0)
    end
  end

  # @spec INTENT-CONFORMANCE-REVIEW-001
  context "when the project has not opted into the rollout flag" do
    before { project.account.tenant_setting!.update!(features: { "approved_intent_amendments" => false }) }

    it "is a no-op and persists nothing" do
      expect(call).to be_nil
      expect(IntentConformanceVerdict.count).to eq(0)
    end
  end

  # @spec INTENT-CONFORMANCE-REVIEW-005
  context "when the PR issue is not trusted" do
    let(:issue) { create(:issue, :pull_request, project: project, github_number: 42, github_creator_login: "attacker") }

    it "records not_evaluated without sending any content to the reviewer" do
      expect(AgentHarness).not_to receive(:send_message)

      verdict = call

      expect(verdict).to be_not_evaluated
      expect(verdict.pr_head_sha).to eq(pr_head_sha)
      expect(verdict.approved_design_revision).to eq("rev1")
    end
  end

  # @spec INTENT-CONFORMANCE-REVIEW-007
  context "when the feature intent has no design document paths" do
    let(:feature_intent) do
      create(:feature_intent, project: project, status: "released", approved_design_revision: "rev1", design_document_paths: [])
    end

    it "records not_evaluated without calling the reviewer" do
      expect(AgentHarness).not_to receive(:send_message)

      expect(call).to be_not_evaluated
    end
  end

  # @spec INTENT-CONFORMANCE-REVIEW-007
  context "when none of the design document paths resolve to readable content" do
    before do
      allow(github_client).to receive(:file_content)
        .with("acme/widgets", path: "docs/rdrs/RDR-999-example.md", ref: "rev1")
        .and_return(nil)
    end

    it "records not_evaluated without calling the reviewer" do
      expect(AgentHarness).not_to receive(:send_message)

      expect(call).to be_not_evaluated
    end
  end

  context "when the reviewer call succeeds" do
    # @spec INTENT-CONFORMANCE-REVIEW-002
    it "persists a within_scope verdict with reviewer evidence bound to the exact head and revision" do
      allow(AgentHarness).to receive(:send_message).and_return(response_double(output: {
        outcome: "within_scope",
        cited_design_claims: [],
        cited_diff_locations: [ { file: "app/models/widget.rb", note: "Color logic unchanged" } ],
        reasoning_summary: "The PR keeps the widget blue as required."
      }.to_json))

      verdict = call

      expect(verdict).to be_within_scope
      expect(verdict.pr_head_sha).to eq(pr_head_sha)
      expect(verdict.approved_design_revision).to eq("rev1")
      expect(verdict.reviewer_model).to eq("claude-sonnet-4-6")
      expect(verdict.reviewer_run_id).to be_present
      expect(verdict.cited_diff_locations).to eq([ { "file" => "app/models/widget.rb", "note" => "Color logic unchanged" } ])
      expect(verdict.reasoning_summary).to eq("The PR keeps the widget blue as required.")
      expect(verdict.recorded_at).to be_present
    end

    it "persists a material_drift verdict when the reviewer cites a changed claim" do
      allow(AgentHarness).to receive(:send_message).and_return(response_double(output: {
        outcome: "material_drift",
        cited_design_claims: [ "The widget SHALL always be blue." ],
        cited_diff_locations: [ { file: "app/models/widget.rb", note: "Now defaults to red" } ],
        reasoning_summary: "The PR changes the widget's default color from blue to red."
      }.to_json))

      verdict = call

      expect(verdict).to be_material_drift
      expect(verdict.cited_design_claims).to eq([ "The widget SHALL always be blue." ])
    end

    it "strips a markdown fence around the JSON output" do
      fenced = "```json\n" + { outcome: "within_scope", cited_design_claims: [], cited_diff_locations: [], reasoning_summary: "OK" }.to_json + "\n```"
      allow(AgentHarness).to receive(:send_message).and_return(response_double(output: fenced))

      expect(call).to be_within_scope
    end

    # @spec INTENT-CONFORMANCE-REVIEW-004
    it "never lets the implementing agent's self-reported verification result set the outcome" do
      agent_run = create(:agent_run, :completed, project: project, issue: issue,
        pull_request_number: 42,
        verification_result: { "status" => "passed", "summary" => "All good, fully in scope." })

      allow(AgentHarness).to receive(:send_message) do |prompt, **|
        expect(prompt).to include("self-reported")
        expect(prompt).to include("NOT authoritative")
        response_double(output: {
          outcome: "material_drift",
          cited_design_claims: [ "The widget SHALL always be blue." ],
          cited_diff_locations: [ { file: "app/models/widget.rb", note: "Now red" } ],
          reasoning_summary: "Despite the implementer's self-report, the color constraint changed."
        }.to_json)
      end

      verdict = call

      expect(verdict).to be_material_drift
      expect(agent_run.reload.verification_result["status"]).to eq("passed")
    end
  end

  # @spec INTENT-CONFORMANCE-REVIEW-003
  context "when the reviewer call is unsuccessful" do
    it "records not_evaluated" do
      allow(AgentHarness).to receive(:send_message).and_return(response_double(output: nil, success: false))

      expect(call).to be_not_evaluated
    end
  end

  # @spec INTENT-CONFORMANCE-REVIEW-003
  context "when the reviewer output is not valid JSON" do
    it "records not_evaluated" do
      allow(AgentHarness).to receive(:send_message).and_return(response_double(output: "not json at all"))

      expect(call).to be_not_evaluated
    end
  end

  # @spec INTENT-CONFORMANCE-REVIEW-003
  context "when the reviewer returns an outcome outside the allowed set" do
    it "records not_evaluated rather than trusting the label" do
      allow(AgentHarness).to receive(:send_message).and_return(response_double(output: {
        outcome: "approved",
        cited_design_claims: [],
        cited_diff_locations: [],
        reasoning_summary: "Looks fine."
      }.to_json))

      expect(call).to be_not_evaluated
    end
  end

  # @spec INTENT-CONFORMANCE-REVIEW-003
  context "when the reviewer returns material_drift with no cited claims" do
    it "records not_evaluated instead of an unexplained drift call" do
      allow(AgentHarness).to receive(:send_message).and_return(response_double(output: {
        outcome: "material_drift",
        cited_design_claims: [],
        cited_diff_locations: [],
        reasoning_summary: "Something seems off."
      }.to_json))

      expect(call).to be_not_evaluated
    end
  end

  # @spec INTENT-CONFORMANCE-REVIEW-003
  context "when cited_diff_locations is not an array" do
    it "records not_evaluated" do
      allow(AgentHarness).to receive(:send_message).and_return(response_double(output: {
        outcome: "within_scope",
        cited_design_claims: [],
        cited_diff_locations: "app/models/widget.rb",
        reasoning_summary: "OK"
      }.to_json))

      expect(call).to be_not_evaluated
    end
  end

  # @spec INTENT-CONFORMANCE-REVIEW-006
  context "when called again for a new PR head" do
    it "records a new verdict per call, so IntentConformanceVerdict.current_for reflects the latest review" do
      allow(AgentHarness).to receive(:send_message).and_return(response_double(output: {
        outcome: "within_scope", cited_design_claims: [], cited_diff_locations: [], reasoning_summary: "OK"
      }.to_json))
      first = call

      allow(github_client).to receive(:compare_summary).with("acme/widgets", "base_sha", "head_new").and_return(comparison)
      later = described_class.call(project: project, issue: issue, pr_head_sha: "head_new")

      expect(IntentConformanceVerdict.current_for(issue)).to eq(later)
      expect(IntentConformanceVerdict.current_for(issue)).not_to eq(first)
      expect(later.pr_head_sha).to eq("head_new")
    end
  end
end
