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
  end
end
