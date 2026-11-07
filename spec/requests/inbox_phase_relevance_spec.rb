# frozen_string_literal: true

require "rails_helper"

# RDR-077 §5 surfaces: the Disabled phases view, personal removal, and the
# per-user isolation of both.
#
# @spec INBOX-PHASE-RELEVANCE-002 @spec INBOX-PHASE-RELEVANCE-003
# @spec INBOX-PHASE-RELEVANCE-006
RSpec.describe "Inbox phase relevance and removal" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user, owner: "acme", repo: "alpha") }
  let(:issue) do
    # The distinctive title is the list-row visibility marker; the question
    # text renders on the selected detail, not in the row's default copy
    # (@spec INBOX-DECISION-BRIEF-002).
    create(:issue, :needs_input, project:, github_state: "open", title: "Phase held question",
      needs_input_questions: [ "Phase held question" ])
  end

  before do
    allow(GithubClient).to receive(:new).and_return(instance_double(GithubClient, issue_comments: []))
    sign_in user
    configure_phases
    issue
  end

  def configure_phases(phases = { "issue_preparation" => true })
    project.update!(
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => phases,
        Automation::PhaseSettings::RELEASE_KEY => false,
        Automation::PhaseSettings::DEPLOYMENT_KEY => false
      }
    )
  end

  # @spec INBOX-PHASE-RELEVANCE-002 @spec INBOX-PHASE-RELEVANCE-003
  it "keeps the request out of the default list and inside the Disabled phases view" do
    FeatureFlags.enable!(:automation_phases, project:)
    configure_phases({ "issue_preparation" => false })

    get inbox_path

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("Phase held question")

    get inbox_path(scope: Inbox::Queue::DISABLED_PHASES_SCOPE)

    expect(response.body).to include("Phase held question")

    # The collection response no longer builds the detail, so the operator's
    # browser loads it through the eager detail frame.
    get inbox_entry_path(entry_id: "clarifying_questions:#{issue.id}")

    expect(response.body).to include("Issue preparation")
    expect(response.body).not_to include("Restore to Inbox")
  end

  it "shows the default Inbox scope as selected" do
    FeatureFlags.enable!(:automation_phases, project:)

    get inbox_path

    expect(response.body).to match(/bg-indigo-50[^>]*>\s*Inbox\s*</)
    expect(response.body).not_to match(/bg-indigo-50[^>]*>\s*Removed\s*</)
  end

  it "keeps a hidden request inspectable through its direct link" do
    FeatureFlags.enable!(:automation_phases, project:)
    configure_phases({ "issue_preparation" => false })

    get inbox_entry_path(entry_id: "clarifying_questions:#{issue.id}")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Phase held question")
    expect(response.body).to include("Enable the Issue preparation phase")
  end

  it "hides a request from the default list after Remove from Inbox without resolving it" do
    FeatureFlags.enable!(:automation_phases, project:)

    post inbox_entry_remove_path(entry_id: "clarifying_questions:#{issue.id}")

    expect(response).to redirect_to(inbox_path)
    get inbox_path
    expect(response.body).not_to include("Phase held question")

    expect(issue.reload.paid_state).to eq("needs_input")
    expect(issue.needs_input_questions).to be_present
  end

  it "keeps a removed request available through the Removed view and Restore" do
    FeatureFlags.enable!(:automation_phases, project:)

    post inbox_entry_remove_path(entry_id: "clarifying_questions:#{issue.id}")
    get inbox_path(scope: Inbox::Queue::REMOVED_SCOPE)
    expect(response.body).to include("Phase held question")

    post inbox_entry_restore_path(entry_id: "clarifying_questions:#{issue.id}")
    get inbox_path
    expect(response.body).to include("Phase held question")
  end

  it "leaves the pre-existing behavior untouched while the rollout flag is off" do
    configure_phases({ "issue_preparation" => false })

    get inbox_path

    expect(response.body).to include("Phase held question")
  end

  it "honors personal removal while the rollout flag is off" do
    post inbox_entry_remove_path(entry_id: "clarifying_questions:#{issue.id}")

    get inbox_path
    expect(response.body).not_to include("Phase held question")

    get inbox_path(scope: Inbox::Queue::REMOVED_SCOPE)
    expect(response.body).to include("Phase held question")
  end
end
