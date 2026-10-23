# frozen_string_literal: true

require "rails_helper"

# @spec INBOX-PHASE-RELEVANCE-006 @spec INBOX-PHASE-RELEVANCE-007
# @spec INBOX-PHASE-RELEVANCE-008 @spec INBOX-PHASE-RELEVANCE-010
RSpec.describe Inbox::Removals do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:other_user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) do
    create(:issue, :needs_input, project:, github_state: "open",
      needs_input_questions: [ "Which behavior?" ])
  end

  before do
    allow(GithubClient).to receive(:new).and_return(instance_double(GithubClient, issue_comments: []))
    FeatureFlags.enable!(:automation_phases, project:)
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

  def entry(scope: Inbox::Queue::ACTIONABLE_SCOPE, for_user: user)
    Inbox::Queue.call(user: for_user, project:, scope:).find { |candidate| candidate.issue&.id == issue.id }
  end

  def remove!(for_user: user, target: entry)
    Inbox::Removals::Remove.call(entry: target, user: for_user)
  end

  describe "removal" do
    it "hides the request for the acting user only" do
      remove!

      expect(entry).to be_nil
      expect(InboxRemoval.active.pluck(:user_id)).to eq([ user.id ])
      expect(Inbox::Removals::Suppression.call(user: other_user, entries: [ entry(scope: Inbox::Queue::REMOVED_SCOPE) ]))
        .to be_empty
    end

    it "does not resolve the request, clear its questions, or change its history" do
      questions_before = issue.reload.needs_input_questions
      remove!

      expect(issue.reload.paid_state).to eq("needs_input")
      expect(issue.needs_input_questions).to eq(questions_before)
    end

    it "stays inspectable through the Removed view and a direct link" do
      remove!

      expect(entry(scope: Inbox::Queue::REMOVED_SCOPE)).to be_present
      expect(Inbox::FindEntry.call(user:, entry_id: "clarifying_questions:#{issue.id}")).to be_present
    end

    it "does not change automation authorization for the underlying work" do
      remove!

      expect(Automation::EffectivePolicy.call(
        project:, phase: "issue_preparation", work_item: issue, trigger: :automatic
      )).to be_permitted
    end

    it "survives rebuilding the derived queue" do
      remove!

      expect(Inbox::Queue.call(user:, project:)).to be_empty
      expect(Inbox::Queue.call(user:, project:).map(&:id)).not_to include("clarifying_questions:#{issue.id}")
    end
  end

  describe "return events" do
    it "restores when the responsible phase transitions from disabled to enabled" do
      configure_phases({ "issue_preparation" => false })
      remove!(target: entry(scope: Inbox::Queue::DISABLED_PHASES_SCOPE))
      expect(entry).to be_nil

      Automation::PhaseSettings::Update.call(project:, params: { "phases" => { "issue_preparation" => true } })

      expect(entry).to be_present
      expect(entry(scope: Inbox::Queue::REMOVED_SCOPE)).to be_nil
    end

    it "does not restore when an already-enabled phase is saved unchanged" do
      remove!

      Automation::PhaseSettings::Update.call(project:, params: { "phases" => { "issue_preparation" => true } })

      expect(entry).to be_nil
    end

    it "keeps each user's suppression independent when the phase is re-enabled" do
      actionable_entry = entry
      Inbox::Removals::Remove.call(entry: actionable_entry, user:)
      Inbox::Removals::Remove.call(entry: actionable_entry, user: other_user)
      configure_phases({ "issue_preparation" => false })

      Automation::PhaseSettings::Update.call(project:, params: { "phases" => { "issue_preparation" => true } })

      expect(InboxRemoval.active.count).to eq(0)
      expect(entry).to be_present
    end

    it "restores when manual work produces a fresh occurrence of the same request" do
      remove!

      # A manual enhancement rerun that asks the same questions produces a new
      # occurrence; the stored removal is now older than the request.
      issue.update!(needs_input_since: Time.current + 5.minutes)

      expect(entry).to be_present
    end

    it "does not restore from polling, an unchanged save, or a retry" do
      remove!

      issue.touch
      Inbox::Queue.call(user:, project:)
      create(:agent_run, project:, issue:, goal: "enhance_issue", trigger_type: "automatic", status: "queued")

      expect(entry).to be_nil
    end

    it "does not let a delayed event from the removed occurrence resurrect the item" do
      remove!
      removal = InboxRemoval.active.find_by(user:, request_key: "clarifying_questions:#{issue.id}")
      stale_occurrence = removal.request_occurrence

      expect(InboxRemoval.new(
        user:, request_key: removal.request_key, entry_kind: removal.entry_kind,
        request_occurrence: stale_occurrence, removed_at: Time.current
      ).suppresses?(stale_occurrence)).to be(true)
    end

    it "does not clear a personal removal when classification happens" do
      remove!

      InboxRequestOwnership.find_by(request_key: "clarifying_questions:#{issue.id}")&.update!(
        classification_state: "classified", responsible_phase: "issue_preparation"
      )

      expect(entry).to be_nil
    end
  end

  describe "restore action" do
    it "returns the request to the default list" do
      remove!

      Inbox::Removals::Restore.call(entry: entry(scope: Inbox::Queue::REMOVED_SCOPE), user:)

      expect(entry).to be_present
    end
  end

  describe "phase-less requests" do
    it "returns on a fresh manual-work condition rather than phase enablement" do
      configure_phases({ "issue_preparation" => false })
      entry(scope: Inbox::Queue::ACTIONABLE_SCOPE)

      platform_entry = Inbox::Queue::Entry.new(
        id: "action_required:1", kind: Inbox::Queue::ACTION_REQUIRED_KIND, project:,
        record: create(:notification, account:, subject: create(:agent_run, project:)),
        waiting_since: Time.current
      )
      Inbox::Removals::Remove.call(entry: platform_entry, user:)
      removal = InboxRemoval.active.find_by(user:, request_key: platform_entry.id)

      # Phase enablement applies only to phase-owned requests.
      Automation::PhaseSettings::Update.call(project:, params: { "phases" => { "issue_preparation" => true } })
      expect(InboxRemoval.active.find_by(id: removal.id)).to be_present

      # A fresh occurrence makes it eligible again.
      expect(removal.suppresses?(removal.request_occurrence)).to be(true)
      expect(removal.suppresses?((Time.current + 60).utc.iso8601(6))).to be(false)
    end
  end
end