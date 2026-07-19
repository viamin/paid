# frozen_string_literal: true

require "rails_helper"
require "psych"

class DeployFile < Pathname
end

RSpec.describe DeployFile, :no_db do
  subject(:deploy_config) { Psych.safe_load_file(Rails.root.join("config/deploy.yml"), aliases: true) }

  it "mounts the docker socket for roles that need the local container backend" do
    servers = deploy_config.fetch("servers")

    expect(servers.fetch("job").dig("options", "volume")).to include("/var/run/docker.sock:/var/run/docker.sock")
    expect(servers.fetch("preview_tunnel").dig("options", "volume")).to include("/var/run/docker.sock:/var/run/docker.sock")
    expect(servers.fetch("worker_agent").dig("options", "volume")).to include("/var/run/docker.sock:/var/run/docker.sock")
  end
end
