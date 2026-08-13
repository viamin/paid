# frozen_string_literal: true

require "rails_helper"

RSpec.describe Previews::Teardown do
  let(:project) { create(:project) }
  let(:session) { create(:preview_session, :ready, project: project, container_id: "preview-container-1") }
  let(:backend) { instance_double(Containers::Backends::Base) }
  let(:logger) { instance_double(ActiveSupport::Logger) }

  before do
    allow(logger).to receive(:warn)
  end

  def container_double(running: true)
    info = { "State" => { "Running" => running } }
    instance_double(Docker::Container, info: info)
  end

  describe ".call" do
    it "releases the tunnel port reservation keyed to the session" do
      reservation = PreviewTunnelPortReservation.create!(
        reservation_key: "preview_session:#{session.id}",
        tunnel_port: 8244
      )
      allow(backend).to receive(:get_container).and_raise(Docker::Error::NotFoundError)

      described_class.call(session, backend: backend, logger: logger)

      expect(PreviewTunnelPortReservation.exists?(reservation.id)).to be(false)
    end

    it "removes a running preview container, stopping it first" do
      container = container_double(running: true)
      allow(backend).to receive(:get_container).with("preview-container-1").and_return(container)
      allow(backend).to receive(:stop_container)
      allow(backend).to receive(:delete_container)

      described_class.call(session, backend: backend, logger: logger)

      expect(backend).to have_received(:stop_container).with(container, timeout: 0)
      expect(backend).to have_received(:delete_container).with(container, force: true, v: true)
    end

    it "deletes without stopping a container that is not running" do
      container = container_double(running: false)
      allow(backend).to receive(:get_container).with("preview-container-1").and_return(container)
      allow(backend).to receive(:stop_container)
      allow(backend).to receive(:delete_container)

      described_class.call(session, backend: backend, logger: logger)

      expect(backend).not_to have_received(:stop_container)
      expect(backend).to have_received(:delete_container).with(container, force: true, v: true)
    end

    it "is a no-op when the container is already gone" do
      allow(backend).to receive(:get_container).with("preview-container-1")
        .and_raise(Docker::Error::NotFoundError)

      expect { described_class.call(session, backend: backend, logger: logger) }.not_to raise_error
      expect(logger).not_to have_received(:warn)
    end

    it "skips container removal when the session has no container id" do
      session.update!(container_id: nil)
      allow(backend).to receive(:get_container)

      described_class.call(session, backend: backend, logger: logger)

      expect(backend).not_to have_received(:get_container)
    end

    it "releases the reservation even when no container was ever provisioned" do
      provisioning = create(:preview_session, :provisioning, project: project, container_id: nil)
      reservation = PreviewTunnelPortReservation.create!(
        reservation_key: "preview_session:#{provisioning.id}",
        tunnel_port: 8245
      )
      allow(backend).to receive(:get_container)

      described_class.call(provisioning, backend: backend, logger: logger)

      expect(PreviewTunnelPortReservation.exists?(reservation.id)).to be(false)
    end

    it "logs but does not raise when a docker error occurs during removal" do
      container = container_double(running: true)
      allow(backend).to receive(:get_container).with("preview-container-1").and_return(container)
      allow(backend).to receive(:stop_container).and_raise(Docker::Error::ServerError, "daemon down")

      expect { described_class.call(session, backend: backend, logger: logger) }.not_to raise_error
      expect(logger).to have_received(:warn) do |payload|
        expect(payload[:message]).to eq("previews.teardown.container_remove_failed")
        expect(payload[:container_id]).to eq("preview-container-1")
      end
    end

    it "still removes the container when port release has nothing to release" do
      container = container_double(running: true)
      allow(backend).to receive(:get_container).with("preview-container-1").and_return(container)
      allow(backend).to receive(:stop_container)
      allow(backend).to receive(:delete_container)

      # No reservation row exists for this session.
      described_class.call(session, backend: backend, logger: logger)

      expect(backend).to have_received(:delete_container).with(container, force: true, v: true)
    end
  end
end
