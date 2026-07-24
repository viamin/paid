# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::RefreshQuotaSnapshotsJob do
  describe "#perform" do
    it "refreshes quota snapshots for each user with subscription runners exactly once" do
      # Users automatically get a default subscription runner (claude) via ensure_default_for
      user_a = create(:user)
      user_b = create(:user)

      allow(Runners::RefreshQuotaSnapshots).to receive(:call)

      described_class.perform_now

      expect(Runners::RefreshQuotaSnapshots).to have_received(:call).with(user: user_a)
      expect(Runners::RefreshQuotaSnapshots).to have_received(:call).with(user: user_b)
      # Each user should be processed only once (DISTINCT in the query)
      expect(Runners::RefreshQuotaSnapshots).to have_received(:call).exactly(User.joins(:runners).merge(Runner.kept_only.subscription).distinct.count).times
    end

    it "uses the maintenance queue" do
      expect(described_class.new.queue_name).to eq("maintenance")
    end
  end
end
