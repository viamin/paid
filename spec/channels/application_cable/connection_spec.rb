# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationCable::Connection do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  it "connects with the current user from warden" do
    connect "/cable", env: { "warden" => instance_double(Warden::Proxy, user: user) }

    expect(connection.current_user).to eq(user)
  end

  it "rejects connections without a signed-in user" do
    expect {
      connect "/cable", env: { "warden" => instance_double(Warden::Proxy, user: nil) }
    }.to have_rejected_connection
  end
end
