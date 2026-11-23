# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::UpdateProjectSettings do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:) }
  let(:session) { create(:chat_session, account:, created_by: owner, project:) }

  def call(settings:, confirmed: true, user: owner)
    described_class.new(user:, session:).call(project_id: project.id, settings:, confirmed:)
  end

  describe ".write_operation?" do
    it { expect(described_class.write_operation?).to be(true) }
  end

  describe ".available_to?" do
    it "is available to an owner with an updatable project" do
      project # ensure an updatable project exists in the account
      expect(described_class).to be_available_to(user: owner)
    end

    it "is not available to a viewer" do
      project
      viewer = create(:user, :viewer, account:)
      expect(described_class).not_to be_available_to(user: viewer)
    end

    it "is not available when the account has no projects" do
      expect(described_class).not_to be_available_to(user: owner)
    end
  end

  describe "#call" do
    # @spec PR-ESCALATION-030
    it "sets a suspension deadline and audits its actor and field" do
      deadline = 1.week.from_now.utc.change(usec: 0)

      result = call(settings: { "pr_escalation_limits_suspended_until" => deadline.iso8601 })

      expect(result[:id]).to eq(project.id)
      expect(project.reload.pr_escalation_limits_suspended_until).to eq(deadline)
      event = account.account_activity_events.last
      expect(event.metadata.fetch("changed_fields")).to include("pr_escalation_limits_suspended_until")
      expect(event.actor_id).to eq(owner.id)
    end

    it "updates permitted attributes and returns them" do
      result = call(settings: { "paused" => true, "auto_pick_enabled" => true })

      expect(result[:id]).to eq(project.id)
      expect(result[:paused]).to be true
      expect(result[:auto_pick_enabled]).to be true
      expect(project.reload).to have_attributes(paused: true, auto_pick_enabled: true)
    end

    it "updates phase settings through the validated transition service" do # @spec AUTOMATION-PHASES-002
      project.update!(automation_phase_settings: { "phases" => { "coding" => false }, "release" => false, "deployment" => true })

      result = call(settings: { "automation_phase_settings" => { "phases" => { "coding" => true }, "release" => true, "deployment" => false } })

      expect(result).to include(automation_phase_settings: hash_including("release" => true, "deployment" => false), enabled_transitions: include("coding"))
      expect(Automation::PhaseSettings.call(project.reload)).to have_attributes(release_enabled?: true, deployment_enabled?: false)
    end

    it "audits every field in a combined settings update" do # @spec AUTOMATION-PHASES-019
      call(settings: {
        "paused" => true,
        "automation_phase_settings" => { "phases" => { "coding" => true } }
      })

      expect(account.account_activity_events.last.metadata.fetch("changed_fields"))
        .to contain_exactly("paused", "automation_phase_settings")
    end

    it "rolls back phase settings when another setting is invalid" do # @spec AUTOMATION-PHASES-019
      original_settings = project.automation_phase_settings
      original_poll_interval = project.poll_interval_seconds

      expect {
        call(settings: {
          "automation_phase_settings" => { "phases" => { "coding" => true } },
          "poll_interval_seconds" => 59
        })
      }.to raise_error(ActiveRecord::RecordInvalid, /Poll interval seconds/)

      expect(project.reload.automation_phase_settings).to eq(original_settings)
      expect(project.poll_interval_seconds).to eq(original_poll_interval)
      expect(account.account_activity_events).to be_empty
    end

    it "does not reconcile phase removals when another setting is invalid" do # @spec AUTOMATION-PHASES-019
      FeatureFlags.enable!(:automation_phases, project:)
      project.update!(created_by: owner, automation_phase_settings: {
        "phases" => { "issue_preparation" => false }, "release" => false, "deployment" => false
      })
      issue = create(:issue, :needs_input, project:, github_state: "open", needs_input_questions: [ "Which behavior?" ])
      allow(GithubClient).to receive(:new).and_return(instance_double(GithubClient, issue_comments: []))
      entry = Inbox::Queue.call(user: owner, project:, scope: Inbox::Queue::DISABLED_PHASES_SCOPE)
        .find { |candidate| candidate.issue&.id == issue.id }
      removal = Inbox::Removals::Remove.call(entry:, user: owner)

      expect {
        call(settings: {
          "automation_phase_settings" => { "phases" => { "issue_preparation" => true } },
          "poll_interval_seconds" => 59
        })
      }.to raise_error(ActiveRecord::RecordInvalid, /Poll interval seconds/)

      expect(removal.reload).to be_active
      expect(InboxHistoryEvent.where(metadata: { "action" => "Restored to Inbox" })).not_to exist
    end

    # @spec FACET-CONFIDENCE-010
    it "updates and returns independently configured confidence thresholds" do
      result = call(settings: { "intent_threshold" => 70, "technical_threshold" => 90 })

      expect(result).to include(intent_threshold: 70, technical_threshold: 90)
      expect(project.reload).to have_attributes(intent_threshold: 70, technical_threshold: 90)
    end

    it "updates the upstream PR target settings" do # @spec PR-TARGET-012
      result = call(settings: {
        "pr_target" => "upstream",
        "upstream_full_name" => "stenolabs/stenoai",
        "auto_add_labels_enabled" => false,
        "inherit_priority_labels" => false,
        "auto_fix_merge_conflicts" => false
      })

      expect(result).to include(pr_target: "upstream", upstream_full_name: "stenolabs/stenoai")
      expect(project.reload).to have_attributes(pr_target: "upstream", upstream_full_name: "stenolabs/stenoai")
    end

    it "raises when not confirmed" do
      expect {
        call(settings: { "paused" => true }, confirmed: false)
      }.to raise_error(ArgumentError, /Confirmation required/)
    end

    it "raises when settings is not an object" do
      expect {
        call(settings: "nope")
      }.to raise_error(ArgumentError, /settings must be an object/)
    end

    it "slices to permitted attributes, ignoring identity and credential fields" do
      original_name = project.name
      original_repo = project.repo

      call(settings: {
        "paused" => true,
        "name" => "Hacked",
        "repo" => "stolen",
        "github_token_id" => 999_999,
        "webhook_secret" => "leaked"
      })

      expect(project.reload).to have_attributes(paused: true, name: original_name, repo: original_repo)
    end

    it "records an activity event for changed fields" do
      expect {
        call(settings: { "paused" => true })
      }.to change(AccountActivityEvent, :count).by(1)

      event = account.account_activity_events.last
      expect(event).to have_attributes(
        action: "project.settings_changed",
        actor: owner,
        subject: project
      )
      expect(event.metadata["changed_fields"]).to include("paused")
    end

    it "authorizes and audits confidence-delivery enrollment changes" do # @spec CONFIDENCE-DELIVERY-001
      FeatureFlags.enable!(:confidence_driven_delivery, project: project)
      FeatureFlags.enable!(:approved_intent_amendments, project: project)
      FeatureFlags.enable!(:intent_conformance_enforcement, project: project)
      expect {
        call(settings: {
          "new_feature_delivery_policy" => "confidence_driven",
          "confidence_delivery_enrollment_enabled" => true
        })
      }.to change(AccountActivityEvent, :count).by(1)

      expect(project.reload).to have_attributes(
        new_feature_delivery_policy: "confidence_driven",
        confidence_delivery_enrollment_enabled: true
      )
      expect(account.account_activity_events.last.metadata.fetch("changed_fields")).to include(
        "new_feature_delivery_policy", "confidence_delivery_enrollment_enabled"
      )
    end

    it "rejects confidence-delivery enrollment until integrated delivery is rolled out" do # @spec CONFIDENCE-DELIVERY-014
      expect {
        call(settings: { "confidence_delivery_enrollment_enabled" => true })
      }.to raise_error(ActiveRecord::RecordInvalid, /confidence-driven delivery integration rollout/)

      expect(project.reload.confidence_delivery_enrollment_enabled).to be(false)
    end

    it "updates and audits the question-exploration rollout setting" do # @spec QUESTION-EXPLORATION-019
      result = nil
      expect {
        result = call(settings: { "question_exploration_enabled" => true })
      }.to change(AccountActivityEvent, :count).by(1)

      expect(result[:question_exploration_enabled]).to be(true)
      expect(project.reload.question_exploration_enabled).to be(true)
      expect(account.account_activity_events.last.metadata.fetch("changed_fields")).to include(
        "question_exploration_enabled"
      )
    end

    it "does not record activity when nothing changed" do
      project.update!(paused: false)

      expect {
        call(settings: { "paused" => false })
      }.not_to change(AccountActivityEvent, :count)
    end

    it "rejects an unauthorized user" do
      viewer = create(:user, :viewer, account:)
      expect {
        call(settings: { "paused" => true }, user: viewer)
      }.to raise_error(Pundit::NotAuthorizedError)
    end

    it "rejects a project from another account" do
      other_project = create(:project)
      expect {
        described_class.new(user: owner, session:).call(
          project_id: other_project.id, settings: { "paused" => true }, confirmed: true
        )
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    # @spec UPSTREAM-GATE-005
    context "when the project targets PRs at the upstream repository" do
      let(:upstream_session) do
        create(:chat_session, account:, created_by: owner, project: upstream_project)
      end
      let(:upstream_project) { create(:project, :upstream_pr_target, account:) }

      def upstream_call(settings:, confirmed: true, user: owner)
        described_class.new(user:, session: upstream_session).call(
          project_id: upstream_project.id, settings:, confirmed:
        )
      end

      it "rejects enabling a gated setting while upstream mode is active" do
        expect {
          upstream_call(settings: { "auto_merge_mode" => "all" })
        }.to raise_error(ArgumentError, /auto_merge_mode/)
      end

      it "lists every violating gated setting in the error" do
        expect {
          upstream_call(settings: {
            "auto_merge_mode" => "all",
            "auto_release_granularity" => "all",
            "auto_add_labels_enabled" => true,
            "paused" => false
          })
        }.to raise_error(ArgumentError, /auto_merge_mode.*auto_release_granularity.*auto_add_labels_enabled/)
      end

      it "still allows non-gated permitted attributes to be saved" do
        upstream_call(settings: { "paused" => true, "auto_pick_enabled" => false })

        expect(upstream_project.reload).to have_attributes(paused: true, auto_pick_enabled: false)
      end

      it "permits a setting that would not enable the gated feature" do
        expect {
          upstream_call(settings: { "auto_merge_mode" => "off", "owner_reviewer_login" => nil })
        }.not_to raise_error
      end
    end
  end
end
