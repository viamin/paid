# frozen_string_literal: true

require "rails_helper"

RSpec.describe Previews::Expire do
  let(:project) { create(:project) }

  it "stops every expired active session for the project" do
    expired_a = create(:preview_session, :expired, project: project, tunnel_port: 8210)
    expired_b = create(:preview_session, :expired, project: project, tunnel_port: 8211)
    fresh = create(:preview_session, project: project, tunnel_port: 8212, expires_at: 10.minutes.from_now)

    described_class.call(project: project)

    expect(expired_a.reload.status).to eq("stopped")
    expect(expired_a.tunnel_port).to be_nil
    expect(expired_b.reload.status).to eq("stopped")
    expect(expired_b.tunnel_port).to be_nil
    expect(fresh.reload.status).to eq("pending")
  end

  it "only reaps the supplied project when given one" do
    other_project = create(:project)
    mine = create(:preview_session, :expired, project: project, tunnel_port: 8210)
    theirs = create(:preview_session, :expired, project: other_project, tunnel_port: 8211)

    described_class.call(project: project)

    expect(mine.reload.status).to eq("stopped")
    expect(theirs.reload.status).to eq("ready")
  end
end
