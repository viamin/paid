# frozen_string_literal: true

require "rails_helper"

RSpec.describe PreviewSession do
  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:agent_run).optional(true) }
  end

  describe "validations" do
    it { is_expected.to validate_inclusion_of(:status).in_array(PreviewSession::STATUSES) }

    it "validates token uniqueness" do
      existing = create(:preview_session, token: "unique-token")
      duplicate = build(:preview_session, token: "unique-token", project: existing.project)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:token]).to include("has already been taken")
    end

    it "validates tunnel_port as a valid port number when present" do
      session = build(:preview_session, tunnel_port: 99_999)
      expect(session).not_to be_valid
      expect(session.errors[:tunnel_port]).to be_present
    end

    it "allows a nil tunnel_port" do
      session = build(:preview_session, tunnel_port: nil)
      expect(session).to be_valid
    end
  end

  describe "token generation" do
    it "generates a random token on create" do
      session = create(:preview_session)
      expect(session.token).to be_present
      expect(session.token.length).to eq(PreviewSession::TOKEN_LENGTH * 2) # hex
    end

    it "preserves an explicitly set token" do
      session = create(:preview_session, token: "explicit-token")
      expect(session.token).to eq("explicit-token")
    end
  end

  describe "expiry default" do
    it "sets a default expires_at on create" do
      session = create(:preview_session)
      expect(session.expires_at).to be_within(5.seconds).of(PreviewSession::DEFAULT_TTL_SECONDS.from_now)
    end
  end

  describe ".find_accessible_by_token" do
    it "returns an accessible session by token" do
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

  describe "#proxiable?" do
    it "is true for an accessible session with a tunnel port" do
      session = build(:preview_session, tunnel_port: 8201)
      expect(session).to be_proxiable
    end

    it "is false when the session is stopped" do
      session = build(:preview_session, :stopped, tunnel_port: 8201)
      expect(session).not_to be_proxiable
    end

    it "is false when the session has no tunnel port" do
      session = build(:preview_session, :without_port)
      expect(session).not_to be_proxiable
    end

    it "is false when the session is expired" do
      session = build(:preview_session, :expired, tunnel_port: 8201)
      expect(session).not_to be_proxiable
    end
  end

  describe "#touch_last_accessed!" do
    it "persists last_accessed_at when unset" do
      session = create(:preview_session, last_accessed_at: nil)

      session.touch_last_accessed!

      expect(session.reload.last_accessed_at).to be_within(1.second).of(Time.current)
    end

    it "writes when last accessed is older than the throttle window" do
      session = create(:preview_session, last_accessed_at: 5.minutes.ago)
      old = session.last_accessed_at

      session.touch_last_accessed!

      expect(session.reload.last_accessed_at).to be > old
    end

    it "is throttled and skips the write within one minute" do
      session = create(:preview_session, last_accessed_at: 10.seconds.ago)
      original = session.last_accessed_at

      session.touch_last_accessed!

      expect(session.reload.last_accessed_at).to eq(original)
    end

    it "writes even with no tenant context set (proxy runs before ApplicationController)" do
      session = create(:preview_session, last_accessed_at: nil)

      TenantContext.clear!
      session.touch_last_accessed!

      expect(session.reload.last_accessed_at).to be_within(1.second).of(Time.current)
    end
  end

  describe "#proxy_prefix" do
    it "returns the proxy path prefix for the session token" do
      session = build(:preview_session, token: "abc123")
      expect(session.proxy_prefix).to eq("/previews/abc123")
    end
  end
end
