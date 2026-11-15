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
