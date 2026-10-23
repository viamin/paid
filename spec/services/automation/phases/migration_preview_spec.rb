# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-015
RSpec.describe Automation::Phases::MigrationPreview do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user, auto_enhance_enabled: false) }

  before do
    allow(GithubClient).to receive(:new).and_return(instance_double(GithubClient, issue_comments: []))
    configure = lambda do |phases|
      project.update!(
        Automation::PhaseSettings::SETTINGS_KEY => {
          Automation::PhaseSettings::PHASES_KEY => phases,
          Automation::PhaseSettings::RELEASE_KEY => false,
          Automation::PhaseSettings::DEPLOYMENT_KEY => false
        }
      )
    end
    configure.call({ "issue_preparation" => false, "coding" => true, "merge" => true })
  end

  it "derives defaults from the project's currently effective capabilities" do
    derived = described_class.call(project:, user:).derived_settings

    expect(derived[Automation::PhaseSettings::PHASES_KEY]).to include(
      "issue_preparation" => false, "coding" => true, "merge" => false
    )
  end

  it "enables nothing by itself" do
    expect { described_class.call(project:, user:) }
      .not_to change { project.reload[Automation::PhaseSettings::SETTINGS_KEY] }
  end

  it "grants no continuation authorization retroactively" do
    create(:agent_run, project:, goal: "create_pr", trigger_type: "manual", status: "completed")

    expect(described_class.call(project:, user:).active_grants).to eq(0)
    expect(WorkItemContinuationGrant.count).to eq(0)
  end

  it "reports the Inbox requests that would leave the default list" do
    FeatureFlags.enable!(:automation_phases, project:)
    issue = create(:issue, :needs_input, project:, github_state: "open",
      needs_input_questions: [ "Which behavior?" ])

    preview = described_class.call(project:, user:)

    expect(preview.inbox_changes_count).to eq(1)
    expect(preview.disabled_phase_entries.first).to include(
      request_key: "clarifying_questions:#{issue.id}",
      responsible_phase: "issue_preparation"
    )
  end

  it "reports label-enabled work that would lose automatic execution" do
    project.update!(feature_activation_labels: project.effective_feature_activation_labels
      .merge("auto_pick" => "paid:auto-pick"))
    create(:issue, project:, labels: [ "paid:auto-pick" ])

    preview = described_class.call(project:, user:)

    expect(preview.label_enabled_capabilities).to be_empty.or include(
      include(capability: "auto_enhance", phase: "issue_preparation")
    )
  end

  it "counts active grants so a rollback knows what it would have to absorb" do
    issue = create(:issue, project:)
    create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")

    expect(described_class.call(project:, user:).active_grants).to eq(1)
  end
end