# frozen_string_literal: true

require "rails_helper"

RSpec.describe PreviewSessions::ExpireJob do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  it "stops preview sessions whose TTL has passed" do
    expired = create(:preview_session, :expired, project: project, tunnel_port: 8210)
    fresh = create(:preview_session, project: project, tunnel_port: 8211, expires_at: 10.minutes.from_now)

    described_class.new.perform

    expect(expired.reload.status).to eq("stopped")
    expect(expired.tunnel_port).to be_nil
    expect(fresh.reload.status).to eq("pending")
  end

  it "is a no-op when nothing has expired" do
    create(:preview_session, project: project, expires_at: 10.minutes.from_now)

    expect { described_class.new.perform }.not_to raise_error
  end

  it "tears down the tunnel port reservation and preview container before stopping" do
    session = create(:preview_session, :expired, project: project,
      tunnel_port: 8210, container_id: "preview-container-1")
    reservation = PreviewTunnelPortReservation.create!(
      reservation_key: "preview_session:#{session.id}",
      tunnel_port: 8210
    )
    container = instance_double(Docker::Container, info: { "State" => { "Running" => true } })
    backend = instance_double(Containers::Backends::Base)
    allow(Containers).to receive(:backend).and_return(backend)
    allow(backend).to receive(:get_container).with("preview-container-1").and_return(container)
    allow(backend).to receive(:stop_container)
    allow(backend).to receive(:delete_container)

    described_class.new.perform

    expect(session.reload.status).to eq("stopped")
    expect(PreviewTunnelPortReservation.exists?(reservation.id)).to be(false)
    expect(backend).to have_received(:stop_container).with(container, timeout: 0)
    expect(backend).to have_received(:delete_container).with(container, force: true, v: true)
  end
end
