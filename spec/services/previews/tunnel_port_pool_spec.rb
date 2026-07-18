# frozen_string_literal: true

require "rails_helper"

RSpec.describe Previews::TunnelPortPool do
  let(:project) { create(:project) }
  let(:other_project) { create(:project) }
  let(:pool) { described_class.new(range: 9000..9002) }

  describe "#acquire" do
    it "assigns the lowest free port and persists it on the session" do
      session = create(:preview_session, project: project)

      port = pool.acquire(session)

      expect(port).to eq(9000)
      expect(session.reload.tunnel_port).to eq(9000)
    end

    it "skips ports already claimed by other active sessions" do
      _other = create(:preview_session, project: project, status: "ready", tunnel_port: 9000)
      session = create(:preview_session, project: project)

      port = pool.acquire(session)

      expect(port).to eq(9001)
      expect(session.reload.tunnel_port).to eq(9001)
    end

    it "skips ports claimed by active sessions in other accounts" do
      _other = create(:preview_session, project: other_project, status: "ready", tunnel_port: 9000)
      session = create(:preview_session, project: project)

      port = pool.acquire(session)

      expect(port).to eq(9001)
      expect(session.reload.tunnel_port).to eq(9001)
    end

    it "ignores ports held only by terminal sessions" do
      _stopped = create(:preview_session, :stopped, project: project, tunnel_port: 9000)
      session = create(:preview_session, project: project)

      port = pool.acquire(session)

      expect(port).to eq(9000)
    end

    it "keeps ports claimed by expired-but-not-yet-reaped sessions reserved" do
      _expired = create(:preview_session, :expired, project: project, tunnel_port: 9000)
      session = create(:preview_session, project: project)

      port = pool.acquire(session)

      expect(port).to eq(9001)
    end

    it "keeps expired claims in other projects reserved until they are reaped" do
      _expired = create(:preview_session, :expired, project: other_project, tunnel_port: 9000)
      session = create(:preview_session, project: project)

      port = pool.acquire(session)

      expect(port).to eq(9001)
      expect(session.reload.tunnel_port).to eq(9001)
    end

    it "raises Exhausted when every port in the range is claimed" do
      ports = (9000..9002).to_a
      ports.each { |port| create(:preview_session, project: project, status: "ready", tunnel_port: port) }
      session = create(:preview_session, project: project)

      expect { pool.acquire(session) }.to raise_error(described_class::Exhausted, /9000..9002/)
    end

    it "uses system access for global allocation queries" do
      session = create(:preview_session, project: project)
      allow(TenantContext).to receive(:with_system_access).and_call_original

      pool.acquire(session)

      expect(TenantContext).to have_received(:with_system_access).at_least(:once)
    end
  end

  describe "#release" do
    it "clears the session's tunnel_port" do
      session = create(:preview_session, project: project, status: "ready", tunnel_port: 9000)

      pool.release(session)

      expect(session.reload.tunnel_port).to be_nil
    end

    it "is a no-op when the session has no port assigned" do
      session = create(:preview_session, project: project, status: "ready", tunnel_port: nil)

      expect { pool.release(session) }.not_to raise_error
      expect(session.reload.tunnel_port).to be_nil
    end

    it "lets a subsequent acquire reuse the released port" do
      session_a = create(:preview_session, project: project, status: "ready", tunnel_port: 9000)
      pool.release(session_a)

      session_b = create(:preview_session, project: project)
      expect(pool.acquire(session_b)).to eq(9000)
    end

    it "uses system access when clearing a claimed port" do
      session = create(:preview_session, project: project, status: "ready", tunnel_port: 9000)
      allow(TenantContext).to receive(:with_system_access).and_call_original

      pool.release(session)

      expect(TenantContext).to have_received(:with_system_access).at_least(:once)
    end
  end

  describe "concurrency" do
    it "serializes overlapping acquires across projects so each gets a unique port" do
      sessions = [
        create(:preview_session, project: project),
        create(:preview_session, project: other_project),
        create(:preview_session, project: project)
      ]

      ports = sessions.map { |s| Thread.new { pool.acquire(s) }.value }

      expect(ports.uniq).to contain_exactly(9000, 9001, 9002)
      sessions.each do |session|
        expect(session.reload.tunnel_port).to be_in(ports)
      end
    end
  end
end
