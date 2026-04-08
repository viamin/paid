# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Resolve do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  before do
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
  end
end
