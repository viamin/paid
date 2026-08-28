# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Resolve do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  before do
    # Force creation before stubbing so unrelated broadcasts from
    # after_create_commit callbacks (e.g. Project#start_github_polling) don't
    # register as calls on the spy.
    account
    project
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
  end

  describe ".call" do
    it "sets resolved_at on the matching notification" do
      notification = create(:notification, account: account, source: "stalled_draft_pr", subject: project)

      freeze_time do
        described_class.call(account: account, source: "stalled_draft_pr", subject: project)
        expect(notification.reload.resolved_at).to eq(Time.current)
      end
    end

    it "returns the resolved notification" do
      notification = create(:notification, account: account, source: "stalled_draft_pr", subject: project)

      result = described_class.call(account: account, source: "stalled_draft_pr", subject: project)
      expect(result).to eq(notification)
    end

    it "returns nil when no matching notification exists" do
      result = described_class.call(account: account, source: "nonexistent", subject: project)
      expect(result).to be_nil
    end

    it "does not resolve already-resolved notifications" do
      original_time = 1.hour.ago
      create(:notification, account: account, source: "stalled_draft_pr", subject: project, resolved_at: original_time)

      result = described_class.call(account: account, source: "stalled_draft_pr", subject: project)
      expect(result).to be_nil
    end

    it "broadcasts updates via Turbo Streams" do
      create(:notification, account: account, source: "test_rule", subject: project)

      described_class.call(account: account, source: "test_rule", subject: project)

      expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_to).at_least(:once)
    end

    # @spec NOTIFICATION-SEVERITY-004
    it "broadcasts a badge count that excludes remaining info notifications" do
      create(:notification, :info, account: account, source: "info_rule", subject: project)
      create(:notification, :warning, account: account, source: "test_rule", subject: project)

      described_class.call(account: account, source: "test_rule", subject: project)

      expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_to)
        .with(account, :notification_updates, hash_including(locals: hash_including(unread_count: 0)))
    end

    it "does not broadcast when no matching notification exists" do
      described_class.call(account: account, source: "nonexistent", subject: project)

      expect(Turbo::StreamsChannel).not_to have_received(:broadcast_replace_to)
    end

    context "with user-scoped notifications" do
      let(:user) { create(:user) }

      it "resolves only the user-scoped notification" do
        user_notification = create(:notification, account: account, source: "stalled_draft_pr", subject: project, user: user)
        account_notification = create(:notification, account: account, source: "stalled_draft_pr", subject: project, user: nil)

        described_class.call(account: account, source: "stalled_draft_pr", subject: project, user: user)

        expect(user_notification.reload.resolved_at).not_to be_nil
        expect(account_notification.reload.resolved_at).to be_nil
      end

      it "does not resolve another user's notification" do
        other_user = create(:user)
        other_notification = create(:notification, account: account, source: "stalled_draft_pr", subject: project, user: other_user)

        result = described_class.call(account: account, source: "stalled_draft_pr", subject: project, user: user)

        expect(result).to be_nil
        expect(other_notification.reload.resolved_at).to be_nil
      end
    end
  end
end
