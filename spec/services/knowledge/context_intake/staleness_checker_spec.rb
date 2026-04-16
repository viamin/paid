# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ContextIntake::StalenessChecker do
  let(:project) { create(:project) }
  let(:user) { create(:user, account: project.account) }

  describe ".call" do
    it "marks old completed sessions as stale" do
      session = create(:context_intake_session, :completed,
        project: project, started_by: user,
        completed_at: 91.days.ago)

      result = described_class.call(project: project)

      expect(result[:stale_count]).to eq(1)
      expect(session.reload.status).to eq("stale")
    end

    it "does not mark recent sessions as stale" do
      create(:context_intake_session, :completed,
        project: project, started_by: user,
        completed_at: 1.day.ago)

      result = described_class.call(project: project)

      expect(result[:stale_count]).to eq(0)
    end

    it "works without a project scope" do
      create(:context_intake_session, :completed,
        project: project, started_by: user,
        completed_at: 91.days.ago)

      result = described_class.call

      expect(result[:stale_count]).to eq(1)
    end
  end
end
