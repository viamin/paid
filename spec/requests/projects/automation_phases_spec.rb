# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-002 @spec AUTOMATION-PHASES-008
# @spec AUTOMATION-PHASES-015 @spec AUTOMATION-PHASES-016
RSpec.describe "Project automation phases" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }

  before { sign_in user }

  it "renders the settings page" do
    get project_automation_phases_path(project)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Automation phases")
  end

  it "renders each trusted label-enabled work item in the migration preview" do # @spec AUTOMATION-PHASES-015
    configure_trusted_auto_pick_label_preview

    get project_automation_phases_path(project)

    expect(response).to have_http_status(:ok)
    body = Nokogiri::HTML(response.body).text.squish
    expect(body).to include("Trusted label-enabled work")
    expect(body).to include("Trusted labeled issue")
    expect(body).to include("Auto pick in Coding")
    expect(body).to include("would lose automatic execution when this phase is activated")
    expect(body).not_to include("Untrusted provenance issue")
  end

  it "states when no trusted label-enabled work exists" do # @spec AUTOMATION-PHASES-015
    get project_automation_phases_path(project)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("No open work is currently admitted by a trusted activation label")
  end

  it "states when trusted-label provenance is unavailable" do # @spec AUTOMATION-PHASES-015
    configure_trusted_auto_pick_label_preview
    allow(Automation::LabelPolicy).to receive(:label_addition_trust)
      .and_raise(GithubClient::RateLimitError.new)

    get project_automation_phases_path(project)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Trusted-label provenance is currently unavailable")
    expect(response.body).not_to include("No open work is currently admitted by a trusted activation label")
  end

  it "states when the trusted-label preview is truncated by its provenance bound" do # @spec AUTOMATION-PHASES-015
    configure_trusted_auto_pick_label_preview
    allow(Automation::LabelPolicy).to receive(:label_addition_trust).and_return(:trusted)
    (Automation::Phases::MigrationPreview::PROVENANCE_REPLAY_LIMIT + 1).times do
      create(:issue, project:, github_state: "open", labels: [ "paid:auto-pick" ], title: "Bounded provenance issue")
    end

    get project_automation_phases_path(project)

    expect(response).to have_http_status(:ok)
    body = Nokogiri::HTML(response.body).text.squish
    expect(body).to include("Bounded provenance issue")
    expect(body).to include("more labeled work exists and is not listed")
  end

  it "updates the phase controls posted by the settings form" do
    patch project_automation_phases_path(project), params: {
      project: {
        phases: {
          "discovery" => "1", "issue_preparation" => "0", "coding" => "1",
          "merge" => "0", "release_deployment" => "0", "operations" => "0"
        },
        release: "1", deployment: "0"
      }
    }

    expect(response).to redirect_to(project_automation_phases_path(project))
    settings = Automation::PhaseSettings.call(project.reload)
    expect(settings.phase_enabled?("discovery")).to be(true)
    expect(settings.phase_enabled?("coding")).to be(true)
    expect(settings.phase_enabled?("merge")).to be(false)
    expect(settings.release_enabled?).to be(true)
  end

  it "disables a previously enabled phase submitted by the settings form" do
    project.update!(
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => { "discovery" => true, "coding" => true },
        Automation::PhaseSettings::RELEASE_KEY => true,
        Automation::PhaseSettings::DEPLOYMENT_KEY => true
      }
    )

    patch project_automation_phases_path(project), params: {
      project: { phases: { "discovery" => "0", "coding" => "1" }, release: "0", deployment: "0" }
    }

    settings = Automation::PhaseSettings.call(project.reload)
    expect(settings.phase_enabled?("discovery")).to be(false)
    expect(settings.phase_enabled?("coding")).to be(true)
    expect(settings.phase_enabled?("merge")).to be(false)
  end

  it "submits unchecked phase, release, and deployment controls as disabled" do
    project.update!(
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => { "release_deployment" => true },
        Automation::PhaseSettings::RELEASE_KEY => true,
        Automation::PhaseSettings::DEPLOYMENT_KEY => true
      }
    )

    get project_automation_phases_path(project)
    form = Nokogiri::HTML(response.body)

    expect(form.at_css('input[type="hidden"][name="project[release]"][value="0"]')).to be_present
    expect(form.at_css('input[type="hidden"][name="project[deployment]"][value="0"]')).to be_present
    Automation::Phases::ALL.each do |phase|
      expect(form.at_css(%(input[type="hidden"][name="project[phases][#{phase}]"][value="0"]))).to be_present
    end

    patch project_automation_phases_path(project), params: {
      project: { phases: { "release_deployment" => "1" }, release: "0", deployment: "0" }
    }

    settings = Automation::PhaseSettings.call(project.reload)
    expect(settings.release_enabled?).to be(false)
    expect(settings.deployment_enabled?).to be(false)
  end

  it "updates phase controls posted in the API settings shape" do
    patch project_automation_phases_path(project), params: {
      automation_phase_settings: { phases: { "merge" => true }, deployment: true }
    }

    expect(response).to redirect_to(project_automation_phases_path(project))
    settings = Automation::PhaseSettings.call(project.reload)
    expect(settings.phase_enabled?("merge")).to be(true)
    expect(settings.deployment_enabled?).to be(true)
  end

  it "reports when a continuation grant was no longer active" do
    grant = create(:work_item_continuation_grant, project:, issue: create(:issue, project:), completed_at: Time.current)

    delete continuation_grant_project_automation_phases_path(project, grant), as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("revoked" => false, "grant_id" => grant.id)
  end

  it "explains a no-op continuation grant revocation in the HTML flow" do
    grant = create(:work_item_continuation_grant, project:, issue: create(:issue, project:), revoked_at: Time.current)

    delete continuation_grant_project_automation_phases_path(project, grant)

    expect(response).to redirect_to(project_automation_phases_path(project))
    expect(flash[:notice]).to eq("Grant was no longer active; nothing to revoke.")
  end

  it "extends an active grant when the user may delegate the later endpoint" do # @spec AUTOMATION-PHASES-009
    grant = create(:work_item_continuation_grant, project:, issue: create(:issue, project:), start_phase: "coding", endpoint: "coding")

    patch extend_continuation_grant_project_automation_phases_path(project, grant), params: { endpoint: "merge" }

    expect(response).to redirect_to(project_automation_phases_path(project))
    expect(grant.reload.endpoint).to eq("merge")
  end

  it "returns the extension outcome and current notice as JSON" do # @spec AUTOMATION-PHASES-009
    grant = create(:work_item_continuation_grant, project:, issue: create(:issue, project:), start_phase: "coding", endpoint: "coding")

    patch extend_continuation_grant_project_automation_phases_path(project, grant), params: { endpoint: "merge" }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("extended" => true, "endpoint" => "merge", "continuation_notice" => include("You selected"))
  end

  it "renders delegated delivery authority from the shared projection" do # @spec PROJECT-DELEGATION-005
    FeatureFlags.enable!(:project_delegation, project:)
    work_item = create(:issue, project:)
    create(:bounded_delegated_action, project:, issue: work_item, action: "review",
      evidence: Automation::DelegatedActionAdmission.admission_evidence(
        work_item: work_item, action: "review", acceptance_refs: [ "AC-1" ], stop_before_phase: "merge"
      ))
    revoked = create(:bounded_delegated_action, project:, issue: work_item, action: "repair",
      evidence: Automation::DelegatedActionAdmission.admission_evidence(
        work_item: work_item, action: "repair", acceptance_refs: [ "AC-1" ], stop_before_phase: "merge"
      ))
    revoked.update!(status: "revoked")

    get project_automation_phases_path(project)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Delegated delivery actions")
    expect(response.body).to include("review")
    expect(response.body).to include("in force")
    expect(response.body).to include("revoked")
  end

  it "states when the project has no delegated delivery actions" do # @spec PROJECT-DELEGATION-005
    FeatureFlags.enable!(:project_delegation, project:)
    get project_automation_phases_path(project)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("No delegated delivery actions")
  end

  it "hides delegated delivery actions until the project opts in" do # @spec PROJECT-DELEGATION-005
    get project_automation_phases_path(project)

    expect(response.body).not_to include("Delegated delivery actions")
  end

  it "attributes blocked authority to the conservative posture" do # @spec PROJECT-DELEGATION-005
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)
    work_item = create(:issue, project:)
    create(:bounded_delegated_action, project:, issue: work_item, action: "review",
      evidence: Automation::DelegatedActionAdmission.admission_evidence(
        work_item:, action: "review", acceptance_refs: [ "AC-1" ], stop_before_phase: "merge"
      ))

    get project_automation_phases_path(project)

    expect(Nokogiri::HTML(response.body).text.squish).to include("not permitted because posture restricted")
  end

  # Derive the coding phase to disabled while a trusted auto-pick label admits
  # exactly one labeled issue, so the preview has label-enabled work to show.
  def configure_trusted_auto_pick_label_preview
    allow(GithubClient).to receive(:new).and_return(instance_double(GithubClient, issue_comments: []))
    project.update!(
      feature_activation_labels: project.effective_feature_activation_labels.merge("auto_pick" => "paid:auto-pick"),
      auto_pick_enabled: false, auto_scan_prs: false, auto_scan_security: false,
      auto_fix_merge_conflicts: false,
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => { "coding" => false },
        Automation::PhaseSettings::RELEASE_KEY => false,
        Automation::PhaseSettings::DEPLOYMENT_KEY => false
      }
    )
    trusted = create(:issue, project:, github_state: "open", labels: [ "paid:auto-pick" ], title: "Trusted labeled issue")
    create(:issue, project:, github_state: "open", labels: [ "paid:auto-pick" ], title: "Untrusted provenance issue")
    allow(Automation::LabelPolicy).to receive(:label_addition_trust) do |_project, candidate, _label|
      candidate == trusted ? :trusted : :untrusted
    end
    trusted
  end
end
