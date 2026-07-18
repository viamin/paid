# frozen_string_literal: true

require "rails_helper"

RSpec.describe PreviewSession do
  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:agent_run).optional }
    it { is_expected.to belong_to(:created_by).optional }
  end

  describe "validations" do
    subject { build(:preview_session) }

    it { is_expected.to validate_presence_of(:branch_name) }
    it { is_expected.to validate_presence_of(:expires_at) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }

    it "rejects a duplicate token" do
      create(:preview_session, token: "duplicate-token")

      duplicate = build(:preview_session, token: "duplicate-token")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:token]).to include("has already been taken")
    end
  end

  describe ".build_for" do
    let(:project) { create(:project) }

    it "snapshots the detected framework and TTL" do
      allow(project).to receive(:detected_framework).and_return("phoenix")

      session = described_class.build_for(project: project, branch_name: "feature/x")

      expect(session.framework).to eq("phoenix")
      expect(session.expires_at).to be_within(5).of(PreviewSession::DEFAULT_TTL_SECONDS.seconds.from_now)
      expect(session.status).to eq("pending")
    end

    it "honors a custom ttl_seconds argument" do
      session = described_class.build_for(project: project, branch_name: "feature/x", ttl_seconds: 120)

      expect(session.expires_at).to be_within(5).of(120.seconds.from_now)
    end
  end

  describe "status helpers" do
    it "reports active?, live?, and terminal? correctly across states" do
      %w[pending provisioning starting ready].each do |status|
        session = build(:preview_session, status: status)
        expect(session.active?).to be(true), "#{status} should be active"
        expect(session.terminal?).to be(false)
      end

      session = build(:preview_session, :ready)
      expect(session.live?).to be(true)

      %w[stopped failed].each do |status|
        session = build(:preview_session, status: status)
        expect(session.active?).to be(false)
        expect(session.terminal?).to be(true)
      end
    end

    it "clears error_message when leaving failed" do
      session = create(:preview_session, :failed)
      expect(session.error_message).to eq("boom")

      session.status = "ready"
      session.valid?

      expect(session.error_message).to be_nil
    end
  end

  describe "#expired? and #time_remaining" do
    it "is expired when expires_at is in the past" do
      session = build(:preview_session, expires_at: 1.minute.ago)
      expect(session.expired?).to be(true)
      expect(session.time_remaining).to eq(0)
    end

    it "is not expired when expires_at is in the future" do
      session = build(:preview_session, expires_at: 10.minutes.from_now)
      expect(session.expired?).to be(false)
      expect(session.time_remaining).to be > 0
    end
  end

  describe "#ttl_warning?" do
    it "is true when close to expiry but still active" do
      session = build(:preview_session, :ready, expires_at: PreviewSession::EXPIRY_WARNING_SECONDS.seconds.from_now - 5)
      expect(session.ttl_warning?).to be(true)
    end

    it "is false for stopped sessions even if expires_at is past" do
      session = build(:preview_session, :stopped, expires_at: 1.minute.ago)
      expect(session.ttl_warning?).to be(false)
    end
  end

  describe ".active scope" do
    let(:project) { create(:project) }

    it "excludes sessions whose expires_at has passed" do
      fresh = create(:preview_session, project: project, expires_at: 10.minutes.from_now)
      _stale = create(:preview_session, :expired, project: project)

      expect(described_class.active).to contain_exactly(fresh)
    end

    it "excludes terminal statuses even when expires_at is in the future" do
      live = create(:preview_session, project: project, expires_at: 10.minutes.from_now)
      _stopped = create(:preview_session, :stopped, project: project, expires_at: 10.minutes.from_now)

      expect(described_class.active).to contain_exactly(live)
    end
  end

  describe "tunnel_port uniqueness for active sessions" do
    let(:project) { create(:project) }

    it "rejects duplicate active tunnel ports via the partial unique index" do
      create(:preview_session, :ready, project: project, tunnel_port: 8300)

      duplicate = build(:preview_session, :ready, project: project, tunnel_port: 8300)
      duplicate.token = SecureRandom.hex(16)

      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "permits duplicate tunnel ports across terminal sessions" do
      create(:preview_session, :stopped, project: project, tunnel_port: 8300)

      duplicate = build(:preview_session, :stopped, project: project, tunnel_port: 8300)
      duplicate.token = SecureRandom.hex(16)

      expect { duplicate.save!(validate: false) }.not_to raise_error
    end
  end
end
