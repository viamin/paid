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
    issue = create(:issue, :needs_input, project:, github_state: "open",
      needs_input_questions: [ "Which behavior?" ])

    preview = described_class.call(project:, user:)

    expect(preview.inbox_changes_count).to eq(1)
    expect(preview.disabled_phase_entries.first).to include(
      request_key: "clarifying_questions:#{issue.id}",
      responsible_phase: "issue_preparation"
    )
  end

  it "reports each trusted label-enabled work item that would lose automatic execution" do
    configure_disabled_auto_pick_preview
    issue = create(:issue, project:, github_state: "open", labels: [ "paid:auto-pick" ])
    untrusted_issue = create(:issue, project:, github_state: "open", labels: [ "paid:auto-pick" ])
    allow(Automation::LabelPolicy).to receive(:label_addition_trust) do |_project, candidate, _label|
      candidate == issue ? :trusted : :untrusted
    end

    preview = described_class.call(project:, user:)

    expect(preview.label_enabled_work).to contain_exactly(
      include(capability: "auto_pick", phase: "coding", work_item_id: issue.id)
    )
    expect(preview.label_enabled_work).not_to include(include(work_item_id: untrusted_issue.id))
  end

  it "excludes locally activated ignored-mode work with an untrusted label" do
    configure_disabled_auto_pick_preview
    project.update!(label_integration_mode: "ignored")
    issue = create(:issue, project:, github_state: "open", labels: [ "paid:auto-pick" ],
      paid_activation_state: "activated")
    allow(Automation::LabelPolicy).to receive(:trusted_user_added_label?).and_return(false)

    preview = described_class.call(project:, user:)

    expect(preview.label_enabled_work).not_to include(include(work_item_id: issue.id))
  end

  it "reports an available preview when labeled work fits within the provenance bound" do
    configure_disabled_auto_pick_preview
    create(:issue, project:, github_state: "open", labels: [ "paid:auto-pick" ])
    allow(Automation::LabelPolicy).to receive(:label_addition_trust).and_return(:trusted)

    preview = described_class.call(project:, user:)

    expect(preview.label_enabled_work_status).to eq("available")
    expect(preview.label_enabled_work).to contain_exactly(include(capability: "auto_pick", phase: "coding"))
  end

  it "bounds provenance replays per render and reports a truncated preview past the bound" do
    configure_disabled_auto_pick_preview
    limit = described_class::PROVENANCE_REPLAY_LIMIT
    (limit + 5).times { create(:issue, project:, github_state: "open", labels: [ "paid:auto-pick" ]) }
    replayed = []
    allow(Automation::LabelPolicy).to receive(:label_addition_trust) do |_project, candidate, _label|
      replayed << candidate.id
      :trusted
    end
    expect(Rails.logger).to receive(:warn).with(hash_including(
      message: "automation.phases.migration_preview.label_trust_truncated",
      project_id: project.id,
      provenance_replay_limit: limit
    ))

    preview = described_class.call(project:, user:)

    expect(replayed.uniq.size).to eq(limit)
    expect(preview.label_enabled_work.size).to eq(limit)
    expect(preview.label_enabled_work_status).to eq("truncated")
    expect(preview.to_h).to include(label_enabled_work_status: "truncated")
  end

  it "spends the provenance budget on the newest labeled work across capabilities" do
    configure_disabled_auto_pick_preview
    project.update!(
      feature_activation_labels: project.effective_feature_activation_labels.merge("auto_merge" => "paid:auto-merge"),
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => { "coding" => false, "merge" => false },
        Automation::PhaseSettings::RELEASE_KEY => false,
        Automation::PhaseSettings::DEPLOYMENT_KEY => false
      }
    )
    described_class::PROVENANCE_REPLAY_LIMIT.times do
      create(:issue, project:, github_state: "open", labels: [ "paid:auto-pick" ])
    end
    pull_request = create(:issue, :pull_request, project:, github_state: "open", labels: [ "paid:auto-merge" ])
    allow(Automation::LabelPolicy).to receive(:label_addition_trust).and_return(:trusted)

    preview = described_class.call(project:, user:)

    expect(preview.label_enabled_work).to include(
      include(capability: "auto_merge", phase: "merge", work_item_id: pull_request.id)
    )
    expect(preview.label_enabled_work_status).to eq("truncated")
  end

  it "replays shared-label work once before checking each disabled capability" do
    issues = shared_label_issues
    replayed = []
    allow(Automation::LabelPolicy).to receive(:label_addition_trust) do |_project, candidate, _label|
      replayed << candidate.id
      :trusted
    end

    preview = described_class.call(project:, user:)

    expect(replayed.uniq).to match_array(issues.map(&:id))
    expect(preview.label_enabled_work_status).to eq("available")
    expect(preview.label_enabled_work).to match_array(issues.map do |issue|
      include(capability: "auto_enhance", phase: "issue_preparation", work_item_id: issue.id)
    end)
  end

  it "reports trusted-label provenance as unavailable when its history is rate limited" do
    configure_disabled_auto_pick_preview
    create(:issue, project:, github_state: "open", labels: [ "paid:auto-pick" ])
    allow(Automation::LabelPolicy).to receive(:label_addition_trust)
      .and_raise(GithubClient::RateLimitError.new)
    expect(Rails.logger).to receive(:warn).with(
      hash_including(
        message: "automation.phases.migration_preview.label_trust_rate_limited",
        project_id: project.id,
        error_class: "GithubClient::RateLimitError"
      )
    )

    preview = described_class.call(project:, user:)

    expect(preview.label_enabled_work_status).to eq("unavailable")
    expect(preview.to_h).to include(label_enabled_work_status: "unavailable")
    expect(preview.label_enabled_work).to be_empty
    expect(preview.label_enabled_capabilities).to be_empty
  end

  it "reports trusted-label provenance as unavailable when its history cannot be read" do
    configure_disabled_auto_pick_preview
    create(:issue, project:, github_state: "open", labels: [ "paid:auto-pick" ])
    allow(Automation::LabelPolicy).to receive(:label_addition_trust).and_return(:unknown)

    preview = described_class.call(project:, user:)

    expect(preview.label_enabled_work_status).to eq("unavailable")
    expect(preview.label_enabled_work).to be_empty
    expect(preview.label_enabled_capabilities).to be_empty
  end

  it "counts active grants so a rollback knows what it would have to absorb" do
    issue = create(:issue, project:)
    create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")

    expect(described_class.call(project:, user:).active_grants).to eq(1)
  end

  def configure_disabled_auto_pick_preview
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
  end

  def shared_label_issues
    project.update!(
      auto_pick_enabled: false,
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => { "coding" => false, "issue_preparation" => false },
        Automation::PhaseSettings::RELEASE_KEY => false,
        Automation::PhaseSettings::DEPLOYMENT_KEY => false
      }
    )
    create_list(:issue, 13, project:, github_state: "open", labels: [ project.feature_activation_label_for("paid_in_full") ])
  end
end
