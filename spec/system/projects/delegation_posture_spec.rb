# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

# The recurring owner flow for RDR-080 delegation: one settings surface shows
# the effective posture, the delegated work admitted under it, and the
# explicit hold; the owner selects the posture, holds delegated work, sees the
# hold, releases it, and rolls the posture back to conservative. The screen is
# the operator's only entry point for the rollback and hold paths, so it is
# covered end to end here.
#
# @spec PROJECT-DELEGATION-010
RSpec.describe "Project delegation posture settings", system_driver: :rack_test, type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let!(:project) { create(:project, account: account, created_by: owner) }
  let(:issue) { create(:issue, project:) }

  before do
    Warden.test_mode!
    login_as(owner, scope: :user)
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)
  end

  after { Warden.test_reset! }

  def authorize_delegated_review
    create(:bounded_delegated_action,
      project:,
      issue:,
      action: "review",
      created_by: owner,
      evidence: Automation::DelegatedActionAdmission.admission_evidence(
        work_item: issue, action: "review", acceptance_refs: [ "AC-1" ], stop_before_phase: "merge"
      ))
  end

  it "selects the bounded delivery posture and shows the admitted work" do
    visit project_automation_phases_path(project)
    choose "Bounded delivery"
    click_button "Save posture"

    expect(project.reload.delegation_posture.level).to eq("bounded_delivery")

    authorize_delegated_review

    visit project_automation_phases_path(project)
    expect(page).to have_content("admitted under bounded_delivery posture revision 1")
  end

  it "holds delegated work, shows the hold, and releases it" do
    visit project_automation_phases_path(project)

    fill_in "project_delegation_hold[reason]", with: "Waiting for the security review"
    click_button "Hold delegated work"

    expect(page).to have_content("Delegated work is on hold")
    expect(page).to have_content("Waiting for the security review")
    expect(ProjectDelegationHold.held.find_by(project:)).to be_present

    click_button "Release hold"

    expect(page).to have_content("Delegated work is on hold", count: 0)
    expect(ProjectDelegationHold.held.where(project:)).to be_empty
  end

  it "rolls the posture back to conservative and keeps the delegated evidence" do
    visit project_automation_phases_path(project)
    choose "Bounded delivery"
    click_button "Save posture"

    authorization = authorize_delegated_review

    visit project_automation_phases_path(project)
    choose "Conservative (default)"
    click_button "Save posture"

    expect(project.reload.delegation_posture.level).to eq("conservative")
    expect(authorization.reload.evidence).to include("posture_snapshot" => hash_including("revision" => 1))
    expect(AccountActivityEvent.where(action: "project_delegation.rolled_back")).to exist
  end
end
