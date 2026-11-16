# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe "Layered verification audits" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:obligation) do
    create(
      :layered_verification_obligation,
      project:,
      scope_description: "Checkout behavior",
      external_identity: "docs/checkout.md"
    )
  end
  let(:github_client) { instance_double(GithubClient) }
  let(:request_parameters) do
    {
      obligation_ids: [ obligation.id ], target_revision: "main", budget: { max_minutes: 15 },
      selections: { obligation.id => { selected_checks: [ "semantic_audit" ],
        fit: "Review the documented checkout behavior", exclusions: [ "No formal model is declared" ] } }
    }
  end
  let(:nonsemantic_parameters) do
    {
      obligation_ids: [ obligation.id ], target_revision: "main", budget: { max_minutes: 15 },
      selections: { obligation.id => {
        selected_checks: [ "formal_verification" ], fit: "An available TLA+ model checks the invariant",
        exclusions: [ "Semantic audit is not needed for this invariant" ],
        required_inputs: [ "models/Checkout.tla", "models/Checkout.cfg" ]
      } }
    }
  end

  before do
    sign_in user
    allow(FeatureFlags).to receive(:enabled?).and_call_original
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:commit).with(project.full_name, "main")
      .and_return(OpenStruct.new(sha: "a" * 40))
    allow(github_client).to receive(:commit).with(project.full_name, "a" * 40)
      .and_return(OpenStruct.new(sha: "a" * 40))
  end

  # @spec LAYERED-VERIFY-010 LAYERED-VERIFY-013 LAYERED-VERIFY-014
  it "renders the resolved project audit preview without queueing a run" do
    expect {
      post request_layered_verification_audit_project_agent_runs_path(project), params: request_parameters
    }.not_to change { project.agent_runs.where(goal: "layered_verification_audit").count }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(
      "Verification audit preview",
      "Checkout behavior",
      "docs/intent/payments/payment-specs.md",
      "#{'a' * 40}",
      "15",
      "Semantic audit"
    )
    expect(response.body).to match(/name="confirmed"[^>]*value="true"/)
  end

  # @spec LAYERED-VERIFY-021
  it "does not render omissions when every verification check is selected" do
    all_checks_parameters = request_parameters.deep_merge(
      selections: {
        obligation.id => {
          selected_checks: LayeredVerificationCheckResult::PRODUCERS,
          exclusions: []
        }
      }
    )

    post request_layered_verification_audit_project_agent_runs_path(project), params: all_checks_parameters

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("Omissions:")
  end

  it "queues the confirmed preview with its selected checks" do
    expect {
      post request_layered_verification_audit_project_agent_runs_path(project),
        params: request_parameters.merge(confirmed: true)
    }.to change { project.agent_runs.where(goal: "layered_verification_audit").count }.by(1)

    expect(response).to redirect_to(project_agent_run_path(project, project.agent_runs.last))
    expect(project.agent_runs.last.external_metadata.dig(
      "layered_verification", "plan", obligation.id.to_s, "selected_checks"
    )).to eq([ "semantic_audit" ])
    expect(github_client).to have_received(:commit).with(project.full_name, "a" * 40)
  end

  # @spec LAYERED-VERIFY-008 LAYERED-VERIFY-010 LAYERED-VERIFY-015 LAYERED-VERIFY-024
  it "carries clean and contradictory scoped results through completion into report and Inbox" do
    clean, conflict, claim = seeded_obligations
    preview, audit = request_seeded_audit(clean:, conflict:)
    expect(preview).to include(clean.canonical_source_path, conflict.canonical_source_path,
      "Checkout behavior", "A retry captures one charge.", "15", "Semantic audit")
    seed_agent_report(audit:, clean:, conflict:, claim:)
    result = Activities::CompleteLayeredVerificationAuditActivity.new.execute(agent_run_id: audit.id)
    expect(result[:coverage].transform_values { |coverage| coverage[:obligation_coverage] }).to eq(
      clean.id.to_s => "supported", conflict.id.to_s => "contradicted"
    )
    expect(audit.reload.status).to eq("completed")
    expect(clean.check_results.sole).to have_attributes(obligation_coverage: "supported")
    finding = conflict.findings.sole
    expect(finding).to have_attributes(correspondence_claim_type: "business_to_model",
      cause_signature: "duplicate-charge-on-retry", status: "open")
    expect(finding.observations.sole.fetch("check_result_ids")).to eq([ conflict.check_results.sole.id ])

    expect_inbox_finding(finding:, audit:)
  end

  def seeded_obligations
    clean = obligation
    conflict = create(:layered_verification_obligation, project:,
      external_identity: "PAYMENTS-017", scope_description: "A retry captures one charge.")
    [ clean, conflict ].each do |item|
      item.record_approval!(revision: item.external_revision, approval_reference: "pr#1", persisted: true)
    end
    claim = create(:layered_verification_correspondence_claim, obligation: conflict, claim_type: "business_to_model")
    [ clean, conflict, claim ]
  end

  def request_seeded_audit(clean:, conflict:)
    parameters = seeded_request_parameters(clean:, conflict:)
    post request_layered_verification_audit_project_agent_runs_path(project), params: parameters
    expect(response).to have_http_status(:ok)
    preview = response.body
    post request_layered_verification_audit_project_agent_runs_path(project),
      params: parameters.merge(confirmed: true)
    [ preview, project.agent_runs.where(goal: "layered_verification_audit").sole ]
  end

  def expect_inbox_finding(finding:, audit:)
    entries = Inbox::Queue.call(user:, kind: Inbox::Queue::LAYERED_VERIFICATION_FINDING_KIND)
    expect(entries.map(&:record)).to eq([ finding ])
    get inbox_entry_path(entries.sole.id), headers: { "Turbo-Frame" => "inbox-detail" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("A retry captures one charge.", "Two charges were captured on retry.",
      "Only the retry path was examined.", project_agent_run_path(project, audit))
  end

  def seeded_request_parameters(clean:, conflict:)
    request_parameters.deep_merge(
      obligation_ids: [ clean.id, conflict.id ],
      selections: { conflict.id => { selected_checks: [ "semantic_audit" ],
        fit: "Compare the accepted retry claim with implementation evidence",
        exclusions: [ "No formal model is declared" ] } }
    )
  end

  def seed_agent_report(audit:, clean:, conflict:, claim:)
    results = [
      { obligation_id: clean.id, selected_check: "semantic_audit", producer: "semantic_audit",
        execution_state: "completed", obligation_coverage: "supported",
        input_revision: { code: "a" * 40, external_revision: clean.external_revision },
        evidence_summary: { source_passages: [ "Checkout behavior is supported." ] },
        limitations: "Only the selected checkout behavior was examined." },
      { obligation_id: conflict.id, correspondence_claim_id: claim.id, selected_check: "semantic_audit",
        producer: "semantic_audit", execution_state: "completed", obligation_coverage: "contradicted",
        cause_signature: "duplicate-charge-on-retry",
        input_revision: { code: "a" * 40, external_revision: conflict.external_revision },
        evidence_summary: { source_passages: [ "A retry captures one charge." ],
          observed_behavior: "Two charges were captured on retry." },
        limitations: "Only the retry path was examined." }
    ]
    audit.update!(status: "running")
    audit.log!("stdout", "paid-layered-verification-output\n#{JSON.generate(check_results: results)}\n" \
      "paid-layered-verification-output\n")
  end

  it "rejects an invalid budget before rendering the preview" do
    post request_layered_verification_audit_project_agent_runs_path(project),
      params: request_parameters.deep_merge(budget: { max_minutes: 0 })

    expect(response).to redirect_to(project_path(project))
    expect(flash[:alert]).to eq("budget must be between 1 and 120 minutes")
  end

  # @spec LAYERED-VERIFY-012
  it "refuses the audit route before resolving a preview when the feature is disabled" do
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(false)

    post request_layered_verification_audit_project_agent_runs_path(project), params: request_parameters

    expect(response).to redirect_to(project_path(project))
    expect(flash[:alert]).to eq("layered verification is not enabled for this project")
    expect(github_client).not_to have_received(:commit)
  end

  # @spec LAYERED-VERIFY-021
  it "rejects a request whose selected scope has no verification checks" do
    post request_layered_verification_audit_project_agent_runs_path(project), params: {
      obligation_ids: [ obligation.id ], target_revision: "main", budget: { max_minutes: 15 }
    }

    expect(response).to redirect_to(project_path(project))
    expect(flash[:alert]).to eq("select at least one verification check for every obligation")
  end

  # @spec LAYERED-VERIFY-014
  it "exposes the audit request control on the project page only when available" do
    obligation
    get project_path(project)

    expect(response.body).to include(request_layered_verification_audit_project_agent_runs_path(project))
    revision_input = Nokogiri::HTML5(response.body).at_css('input[name="target_revision"]')
    expect(revision_input["maxlength"]).to be_nil

    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(false)

    get project_path(project)

    expect(response.body).not_to include(request_layered_verification_audit_project_agent_runs_path(project))
  end

  # @spec LAYERED-VERIFY-021
  it "offers non-semantic checks and planning rationale on the project form" do
    obligation
    get project_path(project)

    form = Nokogiri::HTML5(response.body).at_css('[data-testid="layered-verification-audit-request"]')
    expect(form.at_css('input[value="formal_verification"]')).to be_present
    expect(form.at_css('input[value="semantic_audit"]')["checked"]).to be_nil
    expect(form.at_css("textarea[name='selections[#{obligation.id}][fit]']")).to be_present
    expect(form.at_css("textarea[name='selections[#{obligation.id}][exclusions][]']")).to be_present
  end

  # @spec LAYERED-VERIFY-021
  it "previews and queues a justified non-semantic check" do
    post request_layered_verification_audit_project_agent_runs_path(project), params: nonsemantic_parameters

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Formal verification", "An available TLA+ model checks the invariant",
      "Semantic audit is not needed for this invariant", "models/Checkout.tla", "models/Checkout.cfg")
    expect(project.agent_runs.where(goal: "layered_verification_audit")).to be_empty

    post request_layered_verification_audit_project_agent_runs_path(project), params: nonsemantic_parameters.merge(confirmed: true)

    expect(response).to redirect_to(project_agent_run_path(project, project.agent_runs.last))
    expect(project.agent_runs.last.external_metadata.dig("layered_verification", "plan", obligation.id.to_s)).to include(
      "selected_checks" => [ "formal_verification" ], "fit" => "An available TLA+ model checks the invariant",
      "exclusions" => [ "Semantic audit is not needed for this invariant" ],
      "required_inputs" => [ "models/Checkout.tla", "models/Checkout.cfg" ]
    )
  end
end
