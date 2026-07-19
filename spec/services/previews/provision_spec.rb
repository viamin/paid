# frozen_string_literal: true

require "rails_helper"

RSpec.describe Previews::Provision do
  let(:project) { create(:project) }
  let(:service) { described_class.new(project: project) }

  describe "#start" do
    it "creates a ready session with a tunnel port and stops nothing else" do
      result = service.start(branch_name: "feature/x")

      expect(result).to be_success
      session = result.session.reload
      expect(session.status).to eq("ready")
      expect(session.tunnel_port).to be_in(Previews.port_range)
      expect(session.container_id).to start_with("preview-")
      expect(session.branch_name).to eq("feature/x")
    end

    it "stops the previously active session before starting a new one" do
      first = service.start(branch_name: "main").session

      second = service.start(branch_name: "feature/y").session

      expect(first.reload.status).to eq("stopped")
      expect(first.tunnel_port).to be_nil
      expect(second.status).to eq("ready")
      expect(second.tunnel_port).to be_in(Previews.port_range)
    end

    it "frees the tunnel port when container backend fails" do
      backend = Class.new do
        include Previews::ContainerBackend
        def self.start(_session)
          raise "docker unavailable"
        end
        def self.stop(_session); true; end
      end

      result = described_class.new(project: project, container_backend: backend)
        .start(branch_name: "main")

      expect(result.success?).to be(false)
      session = result.session.reload
      expect(session.status).to eq("failed")
      expect(session.tunnel_port).to be_nil
    end

    it "reaps expired sessions before acquiring a port" do
      expired = create(:preview_session, :expired, project: project, tunnel_port: Previews.port_range.min)

      expect do
        result = service.start(branch_name: "main")
        expect(result).to be_success
      end.to change { expired.reload.status }.from("ready").to("stopped")

      expect(expired.reload.tunnel_port).to be_nil
    end

    it "serializes the stop-and-create path under the project lock" do
      allow(project).to receive(:with_lock).and_wrap_original do |method, *args, &block|
        method.call(*args, &block)
      end

      service.start(branch_name: "main")

      expect(project).to have_received(:with_lock)
    end

    it "releases the project lock before container start" do
      observed = []
      backend = build_observing_backend(observed)
      lock_state = instrument_project_lock(project)

      result = described_class.new(project: project, container_backend: backend).start(branch_name: "main")

      expect(result).to be_success
      expect(lock_state[:held]).to be(false)
      expect(observed).to eq([ false ])
    end
  end

  describe "#stop" do
    it "is a no-op when there is no active session" do
      expect(service.stop).to be_success
    end

    it "is a no-op for a session that is already terminal" do
      session = create(:preview_session, :stopped, project: project, tunnel_port: nil)
      backend = class_double(Previews::ContainerBackend::Simulated).as_stubbed_const
      allow(backend).to receive(:stop)

      result = described_class.new(project: project, container_backend: backend).stop(session: session)

      expect(result).to be_success
      expect(backend).not_to have_received(:stop)
    end

    it "stops the current active session and releases its tunnel port" do
      started = service.start(branch_name: "main").session
      port = started.tunnel_port

      result = service.stop

      expect(result).to be_success
      expect(started.reload.status).to eq("stopped")
      expect(started.tunnel_port).to be_nil
      expect(port).to be_in(Previews.port_range)
    end

    it "stops the latest non-terminal session even after its TTL has passed" do
      session = create(:preview_session, :expired, project: project, tunnel_port: 8250, container_id: "preview-123")

      result = service.stop

      expect(result).to be_success
      expect(result.session.id).to eq(session.id)
      expect(session.reload.status).to eq("stopped")
      expect(session.tunnel_port).to be_nil
    end

    it "stops a specific session passed in" do
      session = create(:preview_session, :ready, project: project, tunnel_port: 8250)

      result = service.stop(session: session)

      expect(result).to be_success
      expect(session.reload.status).to eq("stopped")
      expect(session.tunnel_port).to be_nil
    end

    it "treats an already-missing container as a successful stop" do
      backend = Class.new do
        include Previews::ContainerBackend

        def self.start(_session)
          raise "not used"
        end

        def self.stop(_session)
          raise "Container preview-123 not found"
        end
      end
      session = create(:preview_session, :ready, project: project, tunnel_port: 8250, container_id: "preview-123")

      result = described_class.new(project: project, container_backend: backend).stop(session: session)

      expect(result).to be_success
      expect(session.reload.status).to eq("stopped")
      expect(session.tunnel_port).to be_nil
    end
  end

  describe "#status" do
    it "returns the most recent session for the project (including terminal)" do
      _old = create(:preview_session, :stopped, project: project, created_at: 2.days.ago)
      fresh = create(:preview_session, :ready, project: project, created_at: 1.hour.ago)

      expect(service.status.id).to eq(fresh.id)
    end

    it "ignores expired active sessions and falls back to the latest terminal session" do
      stopped = create(:preview_session, :stopped, project: project, created_at: 5.minutes.ago)
      create(:preview_session, :expired, project: project, created_at: 1.minute.ago)

      expect(service.status.id).to eq(stopped.id)
    end
  end

  describe "#current" do
    it "ignores expired sessions even if their status is still active" do
      _expired = create(:preview_session, :expired, project: project)

      expect(service.send(:current)).to be_nil
    end
  end

  describe "#restart" do
    it "reuses the latest non-terminal session branch after expiry" do
      create(:preview_session, :expired, project: project, branch_name: "feature/keep-me")

      result = service.restart

      expect(result).to be_success
      expect(result.session.reload.branch_name).to eq("feature/keep-me")
    end

    it "reuses the latest failed session branch when retrying without an explicit branch" do
      create(:preview_session, :failed, project: project, branch_name: "feature/retry-me")

      result = service.restart

      expect(result).to be_success
      expect(result.session.reload.branch_name).to eq("feature/retry-me")
    end
  end

  def build_observing_backend(observed)
    backend = Class.new do
      include Previews::ContainerBackend

      class << self
        attr_accessor :observed
      end

      def self.start(session)
        observed << Thread.current[:preview_lock_held]
        Previews::ContainerBackend::Outcome.new(container_id: "preview-#{session.token[0, 12]}", app_port: 3000)
      end

      def self.stop(_session)
        true
      end
    end

    backend.observed = observed
    backend
  end

  def instrument_project_lock(project)
    lock_state = { held: false }

    allow(project).to receive(:with_lock).and_wrap_original do |method, *args, &block|
      lock_state[:held] = true
      Thread.current[:preview_lock_held] = true
      method.call(*args, &block)
    ensure
      lock_state[:held] = false
      Thread.current[:preview_lock_held] = false
    end

    lock_state
  end
end
