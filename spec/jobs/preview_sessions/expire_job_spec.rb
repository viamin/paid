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

  it "tears down expired live preview resources through the lifecycle service" do
    expired = create(:preview_session, :expired, project: project, tunnel_port: 8210)
    allow(Previews::Lifecycle).to receive(:stop_session!).and_return(true)

    described_class.new.perform

    expect(Previews::Lifecycle).to have_received(:stop_session!).with(
      preview_session: expired,
      terminal_status: "stopped"
    )
  end

  it "is a no-op when nothing has expired" do
    create(:preview_session, project: project, expires_at: 10.minutes.from_now)

    expect { described_class.new.perform }.not_to raise_error
  end
end
