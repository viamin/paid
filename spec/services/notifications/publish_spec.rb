# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Publish do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  before do
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
  end

  describe ".call" do
    it "creates a new notification" do
      expect {
        described_class.call(
          account: account,
          source: "stalled_draft_pr",
          subject: project,
          severity: :warning,
          title: "PR stuck in draft",
          description: "The PR has been in draft for 6 hours",
          nav_section: "projects"
        )
      }.to change(Notification, :count).by(1)
    end

    it "returns the created notification" do
      notification = described_class.call(
        account: account,
        source: "stalled_draft_pr",
        subject: project,
        severity: :warning,
        title: "PR stuck in draft"
      )

      expect(notification).to be_a(Notification)
      expect(notification).to be_persisted
      expect(notification.source).to eq("stalled_draft_pr")
      expect(notification.severity).to eq("warning")
    end

    # @spec NOTIFICATION-SEVERITY-007
    it "defaults blocking to false" do
      notification = described_class.call(
        account: account,
        source: "stalled_draft_pr",
        subject: project,
        severity: :warning,
        title: "PR stuck"
      )

      expect(notification.blocking).to be(false)
    end

    # @spec NOTIFICATION-SEVERITY-007
    it "defaults blocking notification actions to the inbox member route" do
      notification = described_class.call(
        account: account,
        source: "pr_followup_limit_reached",
        subject: project,
        severity: :error,
        blocking: true,
        title: "PR follow-up stopped"
      )

      expect(notification.action_url).to eq("/inbox/action_required:#{notification.id}")
    end

    # @spec NOTIFICATION-SEVERITY-007
    it "preserves an explicit action_url for blocking notifications" do
      notification = described_class.call(
        account: account,
        source: "quality_auto_resume_cooldown",
        subject: project,
        severity: :error,
        blocking: true,
        title: "Needs manual review",
        action_url: "/projects/#{project.id}/quality_dashboard"
      )

      expect(notification.action_url).to eq("/projects/#{project.id}/quality_dashboard")
    end

    # @spec NOTIFICATION-SEVERITY-007
    it "rejects blocking notifications with non-error severity" do
      expect {
        described_class.call(
          account: account,
          source: "bad_blocking",
          subject: project,
          severity: :warning,
          blocking: true,
          title: "Invalid"
        )
      }.to raise_error(ActiveRecord::RecordInvalid, /Blocking requires error severity/)
    end

    context "when called with the same account/source/subject" do
      let(:common_attrs) { { account: account, source: "stalled_draft_pr", subject: project } }

      it "does not create a duplicate notification" do
        described_class.call(**common_attrs, severity: :warning, title: "PR stuck for 3 hours")
        described_class.call(**common_attrs, severity: :error, title: "PR stuck for 6 hours")

        expect(Notification.count).to eq(1)
      end

      it "updates the existing notification with new attributes" do
        first = described_class.call(**common_attrs, severity: :warning, title: "PR stuck for 3 hours", metadata: { hours: 3 })
        second = described_class.call(**common_attrs, severity: :error, title: "PR stuck for 6 hours", metadata: { hours: 6 })

        expect(second.id).to eq(first.id)
        expect(second.severity).to eq("error")
        expect(second.metadata).to eq("hours" => 6)
      end
    end

    it "clears resolved_at when re-publishing a resolved notification" do
      notification = described_class.call(
        account: account,
        source: "stalled_draft_pr",
        subject: project,
        severity: :warning,
        title: "PR stuck"
      )
      notification.update!(resolved_at: Time.current)

      republished = described_class.call(
        account: account,
        source: "stalled_draft_pr",
        subject: project,
        severity: :warning,
        title: "PR stuck again"
      )

      expect(republished.resolved_at).to be_nil
    end

    it "clears read_at when re-publishing a read notification" do
      notification = described_class.call(
        account: account,
        source: "stalled_draft_pr",
        subject: project,
        severity: :warning,
        title: "PR stuck"
      )
      notification.update!(read_at: Time.current)

      republished = described_class.call(
        account: account,
        source: "stalled_draft_pr",
        subject: project,
        severity: :error,
        title: "PR stuck for 6 hours"
      )

      expect(republished.read_at).to be_nil
    end

    it "clears dismissed_at when re-publishing a dismissed notification" do
      notification = described_class.call(
        account: account,
        source: "stalled_draft_pr",
        subject: project,
        severity: :warning,
        title: "PR stuck"
      )
      notification.update!(dismissed_at: Time.current)

      republished = described_class.call(
        account: account,
        source: "stalled_draft_pr",
        subject: project,
        severity: :warning,
        title: "PR stuck again"
      )

      expect(republished.dismissed_at).to be_nil
    end

    it "broadcasts updates via Turbo Streams" do
      described_class.call(
        account: account,
        source: "test_rule",
        subject: project,
        severity: :info,
        title: "Test"
      )

      expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_to).at_least(:once)
    end

    context "when broadcasting the bell badge count" do
      # @spec NOTIFICATION-SEVERITY-004
      it "excludes info notifications from the account stream count" do
        create(:notification, :info, account: account, source: "existing_info")

        described_class.call(
          account: account,
          source: "test_rule",
          subject: project,
          severity: :info,
          title: "Test"
        )

        expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_to)
          .with(account, :notification_updates, hash_including(locals: hash_including(unread_count: 0)))
      end

      # @spec NOTIFICATION-SEVERITY-004
      it "includes warning notifications in the account stream count" do
        described_class.call(
          account: account,
          source: "test_rule",
          subject: project,
          severity: :warning,
          title: "Test"
        )

        expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_to)
          .with(account, :notification_updates, hash_including(locals: hash_including(unread_count: 1)))
      end

      # @spec NOTIFICATION-SEVERITY-004
      it "excludes info notifications from the user stream count" do
        user = create(:user, account: account)
        create(:notification, :info, account: account, user: user, source: "existing_user_info")

        described_class.call(
          account: account,
          source: "user_test_rule",
          subject: project,
          severity: :info,
          title: "Test",
          user: user
        )

        expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_to)
          .with(user, :notification_updates, hash_including(locals: hash_including(unread_count: 0)))
      end
    end
  end
end
