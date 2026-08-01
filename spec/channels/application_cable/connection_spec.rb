# frozen_string_literal: true

require "rails_helper"

# Exercises the REAL ApplicationCable::Connection authorization (no stubbing of
# current_user). This is the coverage that was missing: spec/channels/chat_channel_spec
# uses `stub_connection current_user: ...`, so a regression in connection auth
# (e.g. relying on request.env["warden"], which ActionCable websocket requests
# do not carry) would not surface there.
RSpec.describe ApplicationCable::Connection, type: :channel do
  let(:user) { create(:user) }

  it "authorizes the connection when the cable auth cookie is present and valid" do
    cookies.encrypted[described_class::CABLE_USER_COOKIE] = user.id

    connect

    expect(connection.current_user).to eq(user)
  end

  it "rejects the connection when the cookie is absent" do
    expect {
      connect
    }.to raise_error(ActionCable::Connection::Authorization::UnauthorizedError)
  end

  it "rejects the connection when the cookie references a nonexistent user" do
    cookies.encrypted[described_class::CABLE_USER_COOKIE] = User.maximum(:id).to_i + 1

    expect {
      connect
    }.to raise_error(ActionCable::Connection::Authorization::UnauthorizedError)
  end
end
