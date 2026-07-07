# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationProfiles::Applier do
<<<<<<< HEAD
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account, auto_pick_enabled: false) }
  let(:actor) { create(:user, account: account) }
  let(:profile) { ConfigurationProfiles::Registry.find(:solo_automated) }

  before do
    # solo_automated enables paid-agent review, which normally requires the
    # paid-code-reviewer GitHub App credential; treat that as external.
    allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(true)
  end

  describe ".call with a profile plan" do
    it "writes the target values onto the project" do
      plan = ConfigurationProfiles::Planner.for_profile(project, profile)
      described_class.call(project, plan, actor: actor)

      expect(project.reload.auto_pick_enabled).to be true
      expect(project.reload.auto_merge_mode).to eq("all")
      expect(project.adoption_mode).to eq("full_execution")
      expect(project.quality_gates_enabled?).to be false
    end

    it "records an applied activity event with previous_values for rollback" do
      plan = ConfigurationProfiles::Planner.for_profile(project, profile)
      result = described_class.call(project, plan, actor: actor)

      event = result.activity
      expect(event).to be_an(AccountActivityEvent)
      expect(event.action).to eq("configuration_profile.applied")
      expect(event.subject).to eq(project)
      expect(event.actor).to eq(actor)
      expect(event.metadata["profile_key"]).to eq("solo_automated")
      expect(event.metadata["previous_values"]["auto_pick_enabled"]).to be false
      expect(event.metadata["applied_values"]["auto_pick_enabled"]).to be true
      expect(event.metadata["changed_fields"]).to include("auto_pick_enabled")
    end

    it "is a no-op (and records nothing) when the plan is empty" do
      project.update!(auto_add_labels_enabled: true)
      plan = ConfigurationProfiles::Planner.for_values(project, { auto_add_labels_enabled: true }, label: "noop", source: :custom)
      result = described_class.call(project, plan, actor: actor)

      expect(result.changes).to be_empty
      expect(result.activity).to be_nil
    end

    it "rolls back the transaction if save fails" do
      plan = ConfigurationProfiles::Planner.for_values(
        project, { merge_method: "totally_invalid" }, label: "bad", source: :custom
      )
      expect { described_class.call(project, plan, actor: actor) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(account.account_activity_events.where(action: "configuration_profile.applied")).to be_empty
=======
  let(:user) { create(:user, :owner) }
  let(:account) { user.account }

  def plan_for(changes:, prerequisites: [], project_id: nil)
    ConfigurationProfiles::Plan.new(
      profile_id: "solo_fully_automated",
      project_id: project_id,
      changes: changes,
      prerequisites: prerequisites
    )
  end

  describe "#call" do
    context "when validating the target" do
      it "raises when the profile is not registered" do
        plan = ConfigurationProfiles::Plan.new(profile_id: "not_a_real_profile", project_id: nil)

        expect {
          described_class.call(plan: plan, user: user)
        }.to raise_error(ArgumentError, /Profile not found/)
      end

      it "raises when the plan requires a project level but no project is given" do
        plan = plan_for(changes: [ { level: :project, attribute: "project.poll_interval_seconds", before: 60, after: 30 } ])

        expect {
          described_class.call(plan: plan, user: user)
        }.to raise_error(ArgumentError, /project_id is required/)
      end
    end

    context "when checking prerequisites" do
      let(:plan) do
        plan_for(
          changes: [ { level: :user, attribute: "user_settings.run_concurrency_mode", before: "manual", after: "auto" } ],
          prerequisites: [ { key: "github_app_installed", description: "GitHub App must be installed" } ]
        )
      end

      it "hard-fails without applying any changes when a prerequisite is unmet" do
        create(:user_setting, user: user, run_concurrency_mode: "manual")

        expect {
          described_class.call(plan: plan, user: user)
        }.to raise_error(described_class::UnmetPrerequisiteError, /GitHub App must be installed/)

        expect(user.settings.reload.run_concurrency_mode).to eq("manual")
      end

      it "exposes the unmet prerequisites on the error" do
        expect {
          described_class.call(plan: plan, user: user)
        }.to raise_error(described_class::UnmetPrerequisiteError) do |error|
          expect(error.prerequisites).to contain_exactly(hash_including(key: "github_app_installed"))
        end
      end

      it "treats an unrecognized prerequisite key as unmet (fails closed)" do
        plan = plan_for(
          changes: [ { level: :user, attribute: "user_settings.run_concurrency_mode", before: "manual", after: "auto" } ],
          prerequisites: [ { key: "some_future_prerequisite", description: "Not yet checkable" } ]
        )

        expect {
          described_class.call(plan: plan, user: user)
        }.to raise_error(described_class::UnmetPrerequisiteError)
      end

      it "proceeds when the prerequisite is met" do
        create(:github_installation, account: account)

        result = described_class.call(plan: plan, user: user)

        expect(result[:applied].size).to eq(1)
      end
    end

    context "when applying changes" do
      before { create(:github_installation, account: account) }

      it "updates the live record and returns the actual before/after transition" do
        create(:user_setting, user: user, run_concurrency_mode: "manual")
        plan = plan_for(changes: [
          { level: :user, attribute: "user_settings.run_concurrency_mode", before: "stale-plan-time-value", after: "auto" }
        ])

        result = described_class.call(plan: plan, user: user)

        applied = result[:applied].first
        expect(applied).to include(status: "applied", level: :user, before: "manual", after: "auto")
        expect(user.settings.reload.run_concurrency_mode).to eq("auto")
      end

      it "creates the tenant setting on demand when applying a tenant-level change" do
        plan = plan_for(changes: [
          { level: :tenant, attribute: "tenant_settings.max_concurrent_runs", before: 10, after: 25 }
        ])

        expect {
          described_class.call(plan: plan, user: user)
        }.to change(TenantSetting, :count).by(1)

        expect(account.tenant_setting.max_concurrent_runs).to eq(25)
      end

      it "applies a project-level change when a project is provided" do
        project = create(:project, account: account, poll_interval_seconds: 60)
        plan = plan_for(
          changes: [ { level: :project, attribute: "project.poll_interval_seconds", before: 60, after: 90 } ],
          project_id: project.id
        )

        result = described_class.call(plan: plan, user: user, project: project)

        expect(result[:applied]).to contain_exactly(
          hash_including(status: "applied", level: :project, before: 60, after: 90)
        )
        expect(project.reload.poll_interval_seconds).to eq(90)
      end

      it "resolves the project from a serialized plan when none is passed out-of-band" do
        project = create(:project, account: account, poll_interval_seconds: 60)
        source = plan_for(
          changes: [ { level: :project, attribute: "project.poll_interval_seconds", before: 60, after: 90 } ],
          project_id: project.id
        )

        # Simulate the plan -> confirm -> apply round-trip: the plan is
        # serialized (e.g. to JSON) and handed back to the applier without
        # the project passed out-of-band. The applier must resolve the target
        # from the project_id carried on the plan itself.
        serialized = source.to_h
        restored = ConfigurationProfiles::Plan.new(
          profile_id: serialized[:profile_id],
          project_id: serialized[:project_id],
          changes: serialized[:changes],
          prerequisites: serialized[:prerequisites],
          questions: serialized[:questions]
        )

        result = described_class.call(plan: restored, user: user)

        expect(result[:applied]).to contain_exactly(
          hash_including(status: "applied", level: :project, before: 60, after: 90)
        )
        expect(result[:project_id]).to eq(project.id)
        expect(project.reload.poll_interval_seconds).to eq(90)
      end

      it "skips a change whose attribute is not in the permitted list" do
        plan = plan_for(changes: [
          { level: :user, attribute: "user_settings.not_a_real_attribute", before: nil, after: "x" }
        ])

        result = described_class.call(plan: plan, user: user)

        expect(result[:skipped]).to contain_exactly(
          hash_including(status: "skipped", level: :user, reason: "unknown_attribute")
        )
        expect(result[:applied]).to be_empty
      end

      it "skips an unknown level" do
        plan = plan_for(changes: [
          { level: :mystery, attribute: "mystery.thing", before: nil, after: "x" }
        ])

        result = described_class.call(plan: plan, user: user)

        expect(result[:skipped]).to contain_exactly(hash_including(reason: "unknown_level"))
      end

      it "skips a tenant-level change when the user is not authorized, without blocking other changes" do
        member = create(:user, :member, account: account)
        plan = plan_for(changes: [
          { level: :user, attribute: "user_settings.run_concurrency_mode", before: "manual", after: "auto" },
          { level: :tenant, attribute: "tenant_settings.max_concurrent_runs", before: 10, after: 25 }
        ])

        result = described_class.call(plan: plan, user: member)

        expect(result[:applied]).to contain_exactly(hash_including(level: :user))
        expect(result[:skipped]).to contain_exactly(hash_including(level: :tenant, reason: "unauthorized"))
      end

      it "treats policy helpers that raise as unauthorized skips instead of crashing the apply" do
        plan = plan_for(changes: [
          { level: :user, attribute: "user_settings.run_concurrency_mode", before: "manual", after: "auto" }
        ])

        stub_const("UserSettingPolicy", Class.new do
          def initialize(*); end

          def update?
            raise Pundit::NotAuthorizedError, "denied"
          end
        end)

        result = described_class.call(plan: plan, user: user)

        expect(result[:applied]).to be_empty
        expect(result[:skipped]).to contain_exactly(
          hash_including(level: :user, reason: "unauthorized", detail: "not authorized")
        )
      end

      it "records account activity only when at least one change is applied" do
        plan = plan_for(changes: [
          { level: :user, attribute: "user_settings.not_a_real_attribute", before: nil, after: "x" }
        ])

        expect {
          described_class.call(plan: plan, user: user)
        }.not_to change(AccountActivityEvent, :count)

        plan = plan_for(changes: [
          { level: :user, attribute: "user_settings.run_concurrency_mode", before: "manual", after: "auto" }
        ])

        expect {
          described_class.call(plan: plan, user: user)
        }.to change(AccountActivityEvent, :count).by(1)

        event = AccountActivityEvent.last
        expect(event.action).to eq("configuration_profile.applied")
        expect(event.metadata["profile_id"]).to eq("solo_fully_automated")
      end

      it "rolls back all changes when applying one raises" do
        create(:user_setting, user: user, run_concurrency_mode: "manual", max_concurrent_runs: 2)
        plan = plan_for(changes: [
          { level: :user, attribute: "user_settings.run_concurrency_mode", before: "manual", after: "auto" },
          { level: :user, attribute: "user_settings.max_concurrent_runs", before: 2, after: -1 }
        ])

        expect {
          described_class.call(plan: plan, user: user)
        }.to raise_error(ActiveRecord::RecordInvalid)

        expect(user.settings.reload.run_concurrency_mode).not_to eq("auto")
      end

      it "batches changes to the same record so order-dependent validations do not reject a valid plan" do
        # mode=auto allows a nil max_concurrent_runs. Switching to "manual"
        # requires max_concurrent_runs, so applying these as two separate writes
        # would raise on the first one before the second sets the cap.
        create(:user_setting, user: user, run_concurrency_mode: "auto", max_concurrent_runs: nil)
        plan = plan_for(changes: [
          { level: :user, attribute: "user_settings.run_concurrency_mode", before: "auto", after: "manual" },
          { level: :user, attribute: "user_settings.max_concurrent_runs", before: nil, after: 1 }
        ])

        result = described_class.call(plan: plan, user: user)

        expect(result[:applied]).to contain_exactly(
          hash_including(attribute: "user_settings.run_concurrency_mode", before: "auto", after: "manual"),
          hash_including(attribute: "user_settings.max_concurrent_runs", before: nil, after: 1)
        )
        expect(user.settings.reload).to have_attributes(run_concurrency_mode: "manual", max_concurrent_runs: 1)
      end

      it "applies a full multi-change profile for a user with no persisted UserSetting" do
        plan = ConfigurationProfiles::TeamCollaborativeProfile.build_plan(user: user)

        expect { described_class.call(plan: plan, user: user) }.to(
          change(UserSetting, :count).by(1).and(change(TenantSetting, :count).by(1))
        )

        expect(user.settings).to have_attributes(
          run_concurrency_mode: "manual",
          max_concurrent_runs: 1,
          auto_pick_skip_labels: [ "needs-review" ]
        )
        expect(account.tenant_setting.max_concurrent_runs).to eq(3)
      end
>>>>>>> origin/main
    end
  end
end
