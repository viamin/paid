# frozen_string_literal: true

require "rails_helper"

RSpec.describe ContextIntakeSession do
  subject(:session) { build(:context_intake_session) }

  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:started_by).class_name("User") }
    it { is_expected.to have_many(:context_intake_responses).dependent(:destroy) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_presence_of(:schema_version) }
    it { is_expected.to validate_length_of(:schema_version).is_at_most(20) }
  end

  describe "scopes" do
    let(:project) { create(:project) }
    let(:user) { create(:user, account: project.account) }

    describe ".in_progress" do
      it "returns only in_progress sessions" do
        in_progress = create(:context_intake_session, project: project, started_by: user)
        create(:context_intake_session, :completed, project: project, started_by: user)

        expect(described_class.in_progress).to eq([ in_progress ])
      end
    end

    describe ".completed" do
      it "returns only completed sessions" do
        create(:context_intake_session, project: project, started_by: user)
        completed = create(:context_intake_session, :completed, project: project, started_by: user)

        expect(described_class.completed).to eq([ completed ])
      end
    end

    describe ".for_project" do
      it "returns sessions for the given project" do
        mine = create(:context_intake_session, project: project, started_by: user)
        create(:context_intake_session) # different project

        expect(described_class.for_project(project)).to eq([ mine ])
      end
    end
  end

  describe "#complete!" do
    it "marks the session as completed with a timestamp" do
      session = create(:context_intake_session)
      freeze_time do
        session.complete!
        expect(session.reload.status).to eq("completed")
        expect(session.completed_at).to eq(Time.current)
      end
    end
  end

  describe "#mark_stale!" do
    it "marks the session as stale with a timestamp" do
      session = create(:context_intake_session, :completed)
      freeze_time do
        session.mark_stale!
        expect(session.reload.status).to eq("stale")
        expect(session.stale_at).to eq(Time.current)
      end
    end
  end

  describe "#stale?" do
    it "returns true when status is stale" do
      session = build(:context_intake_session, :stale)
      expect(session).to be_stale
    end

    it "returns true when completed more than 90 days ago" do
      session = build(:context_intake_session, :completed,
        completed_at: 91.days.ago)
      expect(session).to be_stale
    end

    it "returns false when recently completed" do
      session = build(:context_intake_session, :completed,
        completed_at: 1.day.ago)
      expect(session).not_to be_stale
    end
  end

  describe "#progress" do
    it "calculates progress from predefined responses" do
      session = create(:context_intake_session)
      create(:context_intake_response, context_intake_session: session,
        question_key: "q1", section: "s1", is_follow_up: false)
      create(:context_intake_response, :answered, context_intake_session: session,
        question_key: "q2", section: "s1", is_follow_up: false)

      progress = session.progress
      expect(progress[:total]).to eq(2)
      expect(progress[:answered]).to eq(1)
      expect(progress[:percentage]).to eq(50)
    end
  end
end
