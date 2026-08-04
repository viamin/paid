# frozen_string_literal: true

require "rails_helper"

RSpec.describe PreviewSession do
  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:agent_run).optional }
    it { is_expected.to belong_to(:created_by).optional }
  end

  describe "validations" do
    subject(:preview_session) { build(:preview_session) }

    it { is_expected.to validate_presence_of(:branch_name) }
    it { is_expected.to validate_presence_of(:expires_at) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }

    it "rejects a duplicate token" do
      create(:preview_session, token: "duplicate-token")

      duplicate = build(:preview_session, token: "duplicate-token")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:token]).to include("has already been taken")
    end

    it "validates tunnel_port as a valid port number when present" do
      session = build(:preview_session, tunnel_port: 99_999)

      expect(session).not_to be_valid
      expect(session.errors[:tunnel_port]).to be_present
    end

    it "allows a nil tunnel_port" do
      expect(build(:preview_session, tunnel_port: nil)).to be_valid
    end
  end

  describe ".build_for" do
    let(:project) { create(:project) }

    it "snapshots the detected framework and TTL" do
      allow(project).to receive(:detected_framework).and_return("phoenix")

      session = described_class.build_for(project:, branch_name: "feature/x")

      expect(session.framework).to eq("phoenix")
      expect(session.expires_at).to be_within(5).of(described_class::DEFAULT_TTL_SECONDS.seconds.from_now)
      expect(session.status).to eq("pending")
    end

    it "honors a custom ttl_seconds argument" do
      session = described_class.build_for(project:, branch_name: "feature/x", ttl_seconds: 120)

      expect(session.expires_at).to be_within(5).of(120.seconds.from_now)
    end
  end

  describe "#framework_label" do
    it "formats the stored framework key for preview metadata" do
      session = build(:preview_session, framework: "phoenix")

      expect(session.framework_label).to eq("Phoenix")
    end

    it "returns nil when no framework is stored" do
      expect(build(:preview_session, framework: nil).framework_label).to be_nil
    end
  end

  describe ".find_accessible_by_token" do
    it "returns a live session by token" do
      session = create(:preview_session, :ready, token: "active-token")

      expect(described_class.find_accessible_by_token("active-token")).to eq(session)
    end

    it "returns nil for an unknown token" do
      expect(described_class.find_accessible_by_token("nope")).to be_nil
    end

    it "returns nil for a blank token" do
      expect(described_class.find_accessible_by_token("")).to be_nil
      expect(described_class.find_accessible_by_token(nil)).to be_nil
    end

    it "returns nil for an expired session" do
      create(:preview_session, :expired, token: "expired-token")

      expect(described_class.find_accessible_by_token("expired-token")).to be_nil
    end

    it "returns nil for a stopped session" do
      create(:preview_session, :stopped, token: "stopped-token")

      expect(described_class.find_accessible_by_token("stopped-token")).to be_nil
    end
  end

  describe "status helpers" do
    it "reports active?, live?, and terminal? correctly across states" do
      %w[pending provisioning starting ready].each do |status|
        session = build(:preview_session, status:)

        expect(session.active?).to be(true), "#{status} should be active"
        expect(session.terminal?).to be(false)
      end

      expect(build(:preview_session, :ready)).to be_live

      %w[stopped failed].each do |status|
        session = build(:preview_session, status:)

        expect(session.active?).to be(false)
        expect(session.terminal?).to be(true)
      end
    end

    it "distinguishes in-progress, pending, provisioning, and starting states" do
      expect(build(:preview_session, status: "pending")).to be_pending
      expect(build(:preview_session, status: "provisioning")).to be_provisioning
      expect(build(:preview_session, status: "starting")).to be_starting

      %w[pending provisioning starting].each do |status|
        expect(build(:preview_session, status:)).to be_in_progress,
          "#{status} should be in progress"
      end

      expect(build(:preview_session, :ready)).not_to be_in_progress
      expect(build(:preview_session, :stopped)).not_to be_in_progress
    end

    it "clears error_message when leaving failed" do
      session = create(:preview_session, :failed)

      session.status = "ready"
      session.valid?

      expect(session.error_message).to be_nil
    end
  end

  describe "#status_label" do
    it "maps each lifecycle status to a user-facing label" do
      expect(build(:preview_session, status: "pending").status_label).to eq("Queued")
      expect(build(:preview_session, status: "provisioning").status_label).to eq("Provisioning")
      expect(build(:preview_session, status: "starting").status_label).to eq("Starting")
      expect(build(:preview_session, status: "ready").status_label).to eq("Ready")
      expect(build(:preview_session, status: "stopped").status_label).to eq("Stopped")
      expect(build(:preview_session, status: "failed").status_label).to eq("Failed")
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
      session = build(
        :preview_session,
        :ready,
        expires_at: described_class::EXPIRY_WARNING_SECONDS.seconds.from_now - 5
      )

      expect(session.ttl_warning?).to be(true)
    end

    it "is false for stopped sessions even if expires_at is past" do
      session = build(:preview_session, :stopped, expires_at: 1.minute.ago)

      expect(session.ttl_warning?).to be(false)
    end
  end

  describe ".active" do
    let(:project) { create(:project) }

    it "excludes sessions whose expires_at has passed" do
      fresh = create(:preview_session, :ready, project:, expires_at: 10.minutes.from_now)
      create(:preview_session, :expired, project:)

      expect(described_class.active).to contain_exactly(fresh)
    end

    it "excludes terminal statuses even when expires_at is in the future" do
      live = create(:preview_session, :ready, project:, expires_at: 10.minutes.from_now)
      create(:preview_session, :stopped, project:, expires_at: 10.minutes.from_now)

      expect(described_class.active).to contain_exactly(live)
    end
  end

  describe "tunnel_port uniqueness for active sessions" do
    let(:project) { create(:project) }

    it "rejects duplicate active tunnel ports via the partial unique index" do
      create(:preview_session, :ready, project:, tunnel_port: 8300)

      duplicate = build(:preview_session, :ready, project:, tunnel_port: 8300)
      duplicate.token = SecureRandom.hex(16)

      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "permits duplicate tunnel ports across terminal sessions" do
      create(:preview_session, :stopped, project:, tunnel_port: 8300)

      duplicate = build(:preview_session, :stopped, project:, tunnel_port: 8300)
      duplicate.token = SecureRandom.hex(16)

      expect { duplicate.save!(validate: false) }.not_to raise_error
    end
  end

  describe "#proxiable?" do
    it "is true for a live session with a tunnel port" do
      expect(build(:preview_session, :ready, tunnel_port: 8201)).to be_proxiable
    end

    it "is false when the session is stopped" do
      expect(build(:preview_session, :stopped, tunnel_port: 8201)).not_to be_proxiable
    end

    it "is false when the session has no tunnel port" do
      expect(build(:preview_session, :ready, :without_port)).not_to be_proxiable
    end

    it "is false when the session is expired" do
      expect(build(:preview_session, :expired, tunnel_port: 8201)).not_to be_proxiable
    end
  end

  describe "#proxy_prefix" do
    it "returns the proxied route prefix for the session token" do
      session = build(:preview_session, token: "preview-token")

      expect(session.proxy_prefix).to eq("/previews/preview-token")
    end
  end

  describe "#touch_last_accessed!" do
    it "persists last_active_at when unset" do
      session = create(:preview_session, :ready, last_active_at: nil)

      session.touch_last_accessed!

      expect(session.reload.last_active_at).to be_within(1.second).of(Time.current)
    end

    it "writes when last active is older than the throttle window" do
      session = create(:preview_session, :ready, last_active_at: 5.minutes.ago)
      original = session.last_active_at

      session.touch_last_accessed!

      expect(session.reload.last_active_at).to be > original
    end

    it "is throttled within one minute" do
      session = create(:preview_session, :ready, last_active_at: 10.seconds.ago)
      original = session.last_active_at

      session.touch_last_accessed!

      expect(session.reload.last_active_at.to_i).to eq(original.to_i)
    end
  end
end
