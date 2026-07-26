# frozen_string_literal: true

require "rails_helper"

RSpec.describe DockerHost, type: :model do
  it "is valid with the factory defaults" do
    expect(build(:docker_host)).to be_valid
  end

  it "requires an endpoint for remote hosts" do
    host = build(:docker_host, endpoint: nil)

    expect(host).not_to be_valid
    expect(host.errors[:endpoint]).to include("can't be blank for remote Docker hosts")
  end

  it "forbids endpoints on the local host" do
    host = build(:docker_host, :local, endpoint: "tcp://localhost:2376")

    expect(host).not_to be_valid
    expect(host.errors[:endpoint]).to include("must be blank for the local Docker host")
  end

  it "does not allow identifier changes after create" do
    host = create(:docker_host)

    host.identifier = "renamed-host"

    expect(host).not_to be_valid
    expect(host.errors[:identifier]).to include("can't be changed after creation")
  end
end
