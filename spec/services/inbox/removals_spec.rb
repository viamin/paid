# frozen_string_literal: true

require "rails_helper"

# @spec INBOX-PHASE-RELEVANCE-006 @spec INBOX-PHASE-RELEVANCE-007
# @spec INBOX-PHASE-RELEVANCE-008 @spec INBOX-PHASE-RELEVANCE-010
RSpec.describe Inbox::Removals do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:other_user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) do
    create(:issue, :needs_input, project:, github_state: "open",
      needs_input_questions: [ "Which behavior?" ])
  end

  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
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
    # @spec INBOX-PHASE-RELEVANCE-009
    it "invalidates the Inbox cache version" do
      previous_version = Dashboard::CacheVersion.current(account, scope: Dashboard::CacheVersion::INBOX_SCOPE)

      remove!

      expect(Dashboard::CacheVersion.current(account, scope: Dashboard::CacheVersion::INBOX_SCOPE))
        .to be > previous_version
    end

    it "restores and removes the same occurrence again" do
      remove!
      Inbox::Removals::Restore.call(entry: entry(scope: Inbox::Queue::REMOVED_SCOPE), user:)

      expect { remove! }.to change { InboxRemoval.active.count }.from(0).to(1)
      expect(InboxRemoval.where(user:, request_key: "clarifying_questions:#{issue.id}").count).to eq(1)
    end

    # @spec OPERATOR-INBOX-023
    it "records remove, restore, and a fresh-occurrence return against the stable issue" do
      remove!
      removed_entry = entry(scope: Inbox::Queue::REMOVED_SCOPE)
      Inbox::Removals::Restore.call(entry: removed_entry, user:)
      remove!
      issue.update!(needs_input_since: Time.current + 5.minutes)

      Inbox::ActionHistory.call(entry: entry, user:)

      expect(InboxHistoryEvent.where(subject_key: "issue:#{project.id}:#{issue.github_number}").pluck(:metadata)).to include(
        include("action" => "Removed from Inbox"), include("action" => "Restored to Inbox"), include("action" => "Returned to Inbox")
      )
      expect(InboxHistoryEvent.find_by!(metadata: { "action" => "Returned to Inbox" })).to have_attributes(
        actor_label: "Paid", source: "paid"
      )
    end

    # @spec INBOX-PHASE-RELEVANCE-008
    it "persists removals for distinct requests sharing an occurrence" do
      occurrence = Time.current
      entries = 2.times.map do
        Inbox::Queue::Entry.new(
          id: "action_required:#{_1}", kind: Inbox::Queue::ACTION_REQUIRED_KIND, project:,
          record: create(:notification, account:, subject: create(:agent_run, project:)), waiting_since: occurrence
        )
      end

      entries.each { Inbox::Removals::Remove.call(entry: _1, user:) }

      expect(InboxRemoval.active.where(user:, request_occurrence: occurrence.utc.iso8601(6)).pluck(:request_key))
        .to match_array(entries.map(&:id))
    end

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
    # @spec INBOX-PHASE-RELEVANCE-009 @spec OPERATOR-INBOX-023
    it "restores when the responsible phase transitions from disabled to enabled" do
      configure_phases({ "issue_preparation" => false })
      remove!(target: entry(scope: Inbox::Queue::DISABLED_PHASES_SCOPE))
      expect(entry).to be_nil
      previous_version = Dashboard::CacheVersion.current(account, scope: Dashboard::CacheVersion::INBOX_SCOPE)

      Automation::PhaseSettings::Update.call(project:, params: { "phases" => { "issue_preparation" => true } })

      expect(entry).to be_present
      expect(entry(scope: Inbox::Queue::REMOVED_SCOPE)).to be_nil
      expect(Dashboard::CacheVersion.current(account, scope: Dashboard::CacheVersion::INBOX_SCOPE))
        .to be > previous_version
      expect(InboxHistoryEvent.find_by!(metadata: { "action" => "Restored to Inbox" })).to have_attributes(
        actor_label: "Paid", source: "paid", result: "completed"
      )
    end

    it "does not restore when an already-enabled phase is saved unchanged" do
      remove!

      Automation::PhaseSettings::Update.call(project:, params: { "phases" => { "issue_preparation" => true } })

      expect(entry).to be_nil
    end

    # @spec INBOX-PHASE-RELEVANCE-004 @spec INBOX-PHASE-RELEVANCE-007
    it "does not clear the removal when the request closed before phase enablement" do
      configure_phases({ "issue_preparation" => false })
      remove!(target: entry(scope: Inbox::Queue::DISABLED_PHASES_SCOPE))
      removal = InboxRemoval.active.find_by!(user:, request_key: "clarifying_questions:#{issue.id}")
      issue.update!(github_state: "closed")

      Automation::PhaseSettings::Update.call(project:, params: { "phases" => { "issue_preparation" => true } })

      expect(removal.reload).to be_active
    end

    it "restores every user's suppression when the phase is re-enabled" do
      actionable_entry = entry
      Inbox::Removals::Remove.call(entry: actionable_entry, user:)
      Inbox::Removals::Remove.call(entry: actionable_entry, user: other_user)
      configure_phases({ "issue_preparation" => false })
      Automation::PhaseSettings::Update.call(project:, params: { "phases" => { "issue_preparation" => true } })

      expect(InboxRemoval.active.where(user:)).not_to exist
      expect(InboxRemoval.active.where(user: other_user)).not_to exist
      expect(entry).to be_present
    end

    it "keeps a removed project setup request suppressed across routine readiness evaluations" do
      setup_project = create(:project, account:, created_by: user, tdd_mode: "strict", readiness_gaps: [
        { "kind" => "missing_ci", "description" => "CI is required." }
      ], readiness_evaluated_at: 1.hour.ago)
      setup_entry = Inbox::Queue.call(user:, project: setup_project).find(&:project_setup_pending?)
      Inbox::Removals::Remove.call(entry: setup_entry, user:)

      setup_project.update!(readiness_evaluated_at: Time.current)

      expect(Inbox::Queue.call(user:, project: setup_project)).to be_empty
    end

    it "restores when manual work produces a fresh occurrence of the same request" do
      remove!

      # A manual enhancement rerun that asks the same questions produces a new
      # occurrence; the stored removal is now older than the request.
      issue.update!(needs_input_since: Time.current + 5.minutes)

      expect(entry).to be_present
    end

    it "removes again after a fresh occurrence without duplicating the removal row" do
      remove!
      issue.update!(needs_input_since: Time.current + 5.minutes)

      expect { remove! }.not_to raise_error
      expect(InboxRemoval.where(user:, request_key: "clarifying_questions:#{issue.id}").count).to eq(1)
      expect(entry).to be_nil
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
    # @spec INBOX-PHASE-RELEVANCE-009
    it "invalidates the Inbox cache version" do
      remove!
      removed_entry = entry(scope: Inbox::Queue::REMOVED_SCOPE)
      previous_version = Dashboard::CacheVersion.current(account, scope: Dashboard::CacheVersion::INBOX_SCOPE)

      Inbox::Removals::Restore.call(entry: removed_entry, user:)

      expect(Dashboard::CacheVersion.current(account, scope: Dashboard::CacheVersion::INBOX_SCOPE))
        .to be > previous_version
    end

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
