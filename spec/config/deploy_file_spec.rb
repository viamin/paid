# frozen_string_literal: true

require "rails_helper"
require "erb"
require "psych"

class DeployFile < Pathname
end

RSpec.describe DeployFile, :no_db do
  let(:deploy_yml_path) { Rails.root.join("config/deploy.yml") }

  def render_deploy_config
    rendered = ERB.new(deploy_yml_path.read, trim_mode: "-").result
    Psych.safe_load(rendered, aliases: true)
  end

  around do |example|
    original = ENV.fetch("CONTAINER_BACKEND", :unset)
    ENV.delete("CONTAINER_BACKEND")
    example.run
  ensure
    if original == :unset
      ENV.delete("CONTAINER_BACKEND")
    else
      ENV["CONTAINER_BACKEND"] = original
    end
  end

  context "with the default local container backend (CONTAINER_BACKEND unset)" do
    subject(:deploy_config) { render_deploy_config }

    let(:socket_roles) { %w[job preview_tunnel worker_agent] }

    it "mounts the docker socket for every role that talks to Docker" do
      servers = deploy_config.fetch("servers")

      socket_roles.each do |role|
        volumes = servers.fetch(role).dig("options", "volume") || []
        expect(volumes).to include("/var/run/docker.sock:/var/run/docker.sock"),
          "expected role #{role.inspect} to mount the docker socket under the local backend"
      end
    end

    it "propagates CONTAINER_BACKEND into the global env so the container runtime matches the mount decision" do
      global_env = deploy_config.fetch("env").fetch("clear")

      expect(global_env.fetch("CONTAINER_BACKEND")).to eq("local")
    end
  end

  context "with CONTAINER_BACKEND=remote" do
    subject(:deploy_config) { render_deploy_config }

    let(:socket_roles) { %w[job preview_tunnel worker_agent] }

    before { ENV["CONTAINER_BACKEND"] = "remote" }

    it "omits the docker socket mount on every role that talks to Docker" do
      servers = deploy_config.fetch("servers")

      socket_roles.each do |role|
        volumes = servers.fetch(role).dig("options", "volume") || []
        expect(volumes).not_to include("/var/run/docker.sock:/var/run/docker.sock"),
          "expected role #{role.inspect} to skip the docker socket mount under the remote backend"
      end
    end

    it "propagates CONTAINER_BACKEND=remote into the global env so the container selects the remote backend" do
      global_env = deploy_config.fetch("env").fetch("clear")

      expect(global_env.fetch("CONTAINER_BACKEND")).to eq("remote")
    end
  end

  context "with CONTAINER_BACKEND=swarm" do
    subject(:deploy_config) { render_deploy_config }

    let(:socket_roles) { %w[job preview_tunnel worker_agent] }

    before { ENV["CONTAINER_BACKEND"] = "swarm" }

    it "omits the docker socket mount on every role that talks to Docker" do
      servers = deploy_config.fetch("servers")

      socket_roles.each do |role|
        volumes = servers.fetch(role).dig("options", "volume") || []
        expect(volumes).not_to include("/var/run/docker.sock:/var/run/docker.sock"),
          "expected role #{role.inspect} to skip the docker socket mount under the swarm backend"
      end
    end

    it "propagates CONTAINER_BACKEND=swarm into the global env so the container selects the swarm backend" do
      global_env = deploy_config.fetch("env").fetch("clear")

      expect(global_env.fetch("CONTAINER_BACKEND")).to eq("swarm")
    end
  end
end
