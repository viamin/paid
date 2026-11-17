# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Layered verification review packages" do
  # @spec LAYERED-VERIFY-023
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:obligation) do
    create(:layered_verification_obligation, project:,
      external_identity: "PAYMENTS-017", scope_description: "A retry captures one charge.")
  end
  let(:audit) do
    run = create(:agent_run, project:, goal: "layered_verification_audit", status: "completed")
    result = create(:layered_verification_check_result, obligation:, agent_run: run,
      obligation_coverage: "supported", input_revision: { "target_revision" => "a" * 40 })
    run.update!(external_metadata: {
      "layered_verification" => {
        "obligation_ids" => [ obligation.id ], "target_revision" => "a" * 40,
        "plan" => { obligation.id.to_s => { "selected_checks" => [ "semantic_audit" ],
                                            "fit" => "Bounded", "exclusions" => [] } },
        "coverage" => { obligation.id.to_s => { "obligation_coverage" => "supported",
                                                "check_result_ids" => [ result.id ] } }
      }
    })
    run
  end
  let!(:package) { LayeredVerification::ReviewPackages::Capture.call(agent_run: audit) }

  before do
    sign_in user
    allow(FeatureFlags).to receive(:enabled?).and_call_original
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
  end

  describe "package history" do
    it "renders the inspectable revision history with bound inputs and approvals" do
      approval = create(:layered_verification_review_approval, package:, approved_by: user,
        provenance: { "surface" => "ui", "note" => "Walkthrough of the retry scenarios." })

      get project_layered_verification_review_packages_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(
        "Review packages",
        package.package_digest,
        "A retry captures one charge.",
        "PAYMENTS-017",
        approval.approved_by.name,
        "Walkthrough of the retry scenarios."
      )
    end

    it "renders the current revision detail with its bound inputs" do
      get project_layered_verification_review_package_path(project, package)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(
        package.package_digest,
        "A retry captures one charge.",
        "a" * 40,
        "Business-intent validation"
      )
    end

    it "exposes package history as JSON for the supported API surface" do
      get project_layered_verification_review_packages_path(project), headers: { "Accept" => "application/json" }

      parsed = JSON.parse(response.body)
      expect(parsed.dig(0, "package_digest")).to eq(package.package_digest)
      expect(parsed.dig(0, "revision_number")).to eq(1)
    end

    # @spec LAYERED-VERIFY-012
    it "refuses the history while the add-on is disabled" do
      allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(false)

      get project_layered_verification_review_packages_path(project)

      expect(response).to redirect_to(project_path(project))
      expect(flash[:alert]).to eq("layered verification is not enabled for this project")
    end

    it "isolates package inspection to the owning account" do
      outsider = create(:user, :owner, account: create(:account))
      sign_in outsider

      get project_layered_verification_review_packages_path(project)

      expect(response).not_to have_http_status(:ok)
      expect(response.body).not_to include(package.package_digest)
    end
  end

  describe "business-review approval" do
    it "records the approval and starts neither repair nor release" do
      expect {
        post approve_project_layered_verification_review_package_path(project, package),
          params: { note: "Validated the retry scenarios at the bound revision." }
      }.not_to change(AgentRun, :count)

      expect(response).to redirect_to(project_layered_verification_review_package_path(project, package))
      approval = package.approvals.sole
      expect(approval).to have_attributes(approved_by: user)
      expect(approval.provenance).to include(
        "surface" => "ui", "note" => "Validated the retry scenarios at the bound revision.",
        "package_digest" => package.package_digest
      )
      expect(obligation.reload.approval_state).to eq("proposed")
      expect(AgentRun.where(goal: "layered_verification_repair", project:)).to be_empty
    end

    it "shows validation recorded through the approval endpoint on its successor revision" do
      post approve_project_layered_verification_review_package_path(project, package),
        params: { note: "Validated the retry scenarios at the bound revision." }

      get project_agent_run_path(project, audit)

      intent_section = section(response.body, "layered-verification-intent-validation")
      expect(intent_section).to include("Validated", user.name)
      expect(intent_section).not_to include("Unknown")
    end

    it "keeps validation unknown when changed evidence succeeds a carried approval" do
      post approve_project_layered_verification_review_package_path(project, package),
        params: { note: "Validated the retry scenarios at the bound revision." }

      LayeredVerificationCheckResult.create!(
        producer: "semantic_audit", execution_state: "completed", obligation_coverage: "unresolved",
        input_revision: { "target_revision" => "a" * 40 }, limitations: "A changed check result.",
        obligation:, agent_run: audit
      )
      current_package = LayeredVerification::ReviewPackages::Capture.call(agent_run: audit)

      expect(current_package.revision_number).to eq(package.revision_number + 2)
      expect(current_package.bound_inputs.fetch("approval_ids")).to contain_exactly(package.approvals.sole.id)

      get project_agent_run_path(project, audit)

      intent_section = section(response.body, "layered-verification-intent-validation")
      expect(intent_section).to include("Unknown")
      expect(intent_section).not_to include("Validated", user.name)
    end

    it "requires refreshed review when a newer revision supersedes the rendered package" do
      obligation.check_results.create!(
        producer: "semantic_audit", execution_state: "completed", obligation_coverage: "unresolved",
        input_revision: { "target_revision" => "a" * 40 }, agent_run: audit, limitations: "A second bounded read."
      )
      LayeredVerification::ReviewPackages::Capture.call(agent_run: audit)

      post approve_project_layered_verification_review_package_path(project, package),
        params: { note: "Approved stale inputs." }

      expect(response).to redirect_to(project_layered_verification_review_package_path(project, package))
      expect(flash[:alert]).to include("newer review package revision")
      expect(package.approvals).to be_empty
    end

    it "refuses approval when the actor cannot manage the project's issues" do
      viewer = create(:user, account:)
      sign_in viewer

      post approve_project_layered_verification_review_package_path(project, package), params: { note: "x" }

      expect(response).not_to have_http_status(:ok)
      expect(package.approvals).to be_empty
    end
  end

  describe "separate audit report views" do
    it "renders business-intent validation and verification coverage as distinct sections" do
      get project_agent_run_path(project, audit)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Business-intent validation", "Verification coverage")
      expect(response.body.index(%q(id="layered-verification-intent-validation")))
        .to be < response.body.index(%q(id="layered-verification-coverage"))
      intent_section = section(response.body, "layered-verification-intent-validation")
      coverage_section = section(response.body, "layered-verification-coverage")
      expect(intent_section).to include("Unknown", "PAYMENTS-017", "Canonical approval")
      expect(intent_section).not_to include("Supported")
      expect(coverage_section).to include("Supported")
    end

    it "keeps an approved business validation explicit in the intent view" do
      LayeredVerification::ReviewPackages::Approve.call(
        package:, user:, provenance: { "surface" => "ui" }
      )

      get project_agent_run_path(project, audit)

      intent_section = section(response.body, "layered-verification-intent-validation")
      expect(intent_section).to include("Validated", user.name)
      expect(intent_section).not_to include("Unknown")
    end

    it "keeps validation unknown explicitly when no package was captured for the run" do
      audit.review_packages.delete_all

      get project_agent_run_path(project, audit)

      intent_section = section(response.body, "layered-verification-intent-validation")
      expect(intent_section).to include("Unknown", "no package captured")
    end
  end

  def section(body, id)
    body[%r{<section[^>]*id="#{id}".*?</section>}m]
  end
end
