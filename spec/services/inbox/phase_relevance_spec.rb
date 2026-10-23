# frozen_string_literal: true

require "rails_helper"

# @spec INBOX-PHASE-RELEVANCE-002 @spec INBOX-PHASE-RELEVANCE-003
# @spec INBOX-PHASE-RELEVANCE-004
RSpec.describe Inbox::PhaseRelevance do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user, auto_enhance_enabled: false) }
  let(:issue) do
    create(:issue, :needs_input, project:, github_state: "open", needs_input_questions: [ "Which behavior?" ])
  end

  before do
    allow(GithubClient).to receive(:new).and_return(instance_double(GithubClient, issue_comments: []))
    FeatureFlags.enable!(:automation_phases, project:)
    configure_phases
    # Materialize the request before any example builds the queue, so the
    # lazily created issue exists in the first query.
    issue
  end

  def configure_phases(phases = { "issue_preparation" => true, "coding" => true, "merge" => true })
    project.update!(
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => phases,
        Automation::PhaseSettings::RELEASE_KEY => false,
        Automation::PhaseSettings::DEPLOYMENT_KEY => false
      }
    )
  end

  def entry(id: nil, scope: Inbox::Queue::ACTIONABLE_SCOPE)
    entry = Inbox::Queue.call(user:, project:, scope:).find { |candidate| candidate.issue&.id == issue.id }
    return entry if entry

    raise "expected an inbox entry for issue #{issue.id}"
  end

  def relevance(id: nil, scope: Inbox::Queue::ACTIONABLE_SCOPE)
    described_class.new.call(entry(id:, scope:))
  end

  describe "phase-enabled projects" do
    it "keeps a request whose phase is enabled in the default Inbox" do
      expect(relevance).to be_actionable
      expect(entry).to be_present
    end

    it "moves a request out of the default Inbox when its phase is disabled" do
      configure_phases({ "issue_preparation" => false })

      expect(relevance(scope: Inbox::Queue::DISABLED_PHASES_SCOPE)).to be_disabled_phase
      expect(Inbox::Queue.call(user:, project:)).to be_empty
    end

    it "keeps a disabled-phase request discoverable with its stop reason and recovery action" do
      configure_phases({ "issue_preparation" => false })
      disabled = relevance(scope: Inbox::Queue::DISABLED_PHASES_SCOPE)

      expect(disabled.stop_reason).to include("Issue preparation")
      expect(disabled.recovery).to include("Enable the Issue preparation phase")
    end

    it "does not resolve or clear the hidden request" do
      configure_phases({ "issue_preparation" => false })

      expect { Inbox::Queue.call(user:, project:, scope: Inbox::Queue::DISABLED_PHASES_SCOPE) }.not_to change(issue, :paid_state)
      expect(issue.reload.needs_input_questions).to be_present
    end
  end

  describe "grants and manual work" do
    before { configure_phases({ "issue_preparation" => false, "coding" => false, "merge" => false }) }

    it "keeps a request actionable while a grant covers its phase and work" do
      create(:work_item_continuation_grant, project:, issue:, start_phase: "issue_preparation", endpoint: "coding")

      expect(relevance).to be_actionable
    end

    it "keeps a request actionable while an explicitly started manual action is outstanding" do
      create(:agent_run, project:, issue:, goal: "create_pr", trigger_type: "manual", status: "queued")

      expect(relevance).to be_actionable
    end

    it "hides the request once the manual action finished and no grant covers it" do
      create(:agent_run, project:, issue:, goal: "create_pr", trigger_type: "manual", status: "completed")

      expect(relevance(scope: Inbox::Queue::DISABLED_PHASES_SCOPE)).to be_disabled_phase
    end

    it "batches phase relevance queries across queue entries" do
      configure_phases({ "issue_preparation" => false })
      Inbox::Queue.new(user:, project:).entries
      single_entry_queries = count_queries { Inbox::Queue.call(user:, project:) }

      3.times do |index|
        create(:issue, :needs_input, project:, github_state: "open",
          github_number: 100 + index, needs_input_questions: [ "Question #{index}?" ])
      end
      Inbox::Queue.new(user:, project:).entries
      multiple_entry_queries = count_queries { Inbox::Queue.call(user:, project:) }

      expect(multiple_entry_queries).to eq(single_entry_queries)
    end

    it "classifies a non-Issue request without looking for an Issue work chain" do
      configure_phases({ "discovery" => false })
      setup_entry = Inbox::Queue::Entry.new(
        id: "project_setup_pending:#{project.id}",
        kind: Inbox::Queue::PROJECT_SETUP_PENDING_KIND,
        project:,
        issue: nil,
        record: project,
        waiting_since: Time.current
      )

      result = described_class.for_entries([ setup_entry ]).fetch(setup_entry.id)

      expect(result).to be_disabled_phase
    end
  end

  describe "phase re-enablement" do
    it "restores a still-actionable request when the phase transitions to enabled" do
      configure_phases({ "issue_preparation" => false })
      request_key = "clarifying_questions:#{issue.id}"
      expect(Inbox::Queue.call(user:, project:)).to be_empty

      Automation::PhaseSettings::Update.call(project:, params: { "phases" => { "issue_preparation" => true } })

      expect(Inbox::Queue.call(user:, project:)).to contain_exactly(have_attributes(id: request_key))
    end

    it "does not restore a closed or superseded request" do
      configure_phases({ "issue_preparation" => false })
      issue.update!(github_state: "closed")

      Automation::PhaseSettings::Update.call(project:, params: { "phases" => { "issue_preparation" => true } })

      expect(Inbox::Queue.call(user:, project:)).to be_empty
    end
  end

  describe "while the rollout flag is off" do
    it "keeps the pre-existing visibility" do
      FeatureFlags.disable!(:automation_phases, project:)
      configure_phases({ "issue_preparation" => false })
      request_key = "clarifying_questions:#{issue.id}"

      expect(Inbox::Queue.call(user:, project:)).to contain_exactly(have_attributes(id: request_key))
    end
  end
end
