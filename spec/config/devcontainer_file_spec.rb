# frozen_string_literal: true

require "rails_helper"
require "json"

class DevcontainerFile < Pathname
end

RSpec.describe DevcontainerFile, :no_db do
  subject(:devcontainer) do
    source = Rails.root.join(".devcontainer/devcontainer.json").read
    JSON.parse(source.lines.reject { |line| line.lstrip.start_with?("//") }.join)
  end

  let(:oh_my_pi_installer) { Rails.root.join(".devcontainer/install-oh-my-pi.sh").read }

  it "installs opencode through the shared contract wrapper" do
    command = devcontainer.fetch("postCreateCommand").fetch("opencode")

    expect(command).to eq("bash scripts/install-from-contract.sh opencode")
  end

  it "installs oh-my-pi through the devcontainer installer" do
    command = devcontainer.fetch("postCreateCommand").fetch("oh-my-pi")
    path = devcontainer.fetch("remoteEnv").fetch("PATH")

    expect(command).to eq("bash .devcontainer/install-oh-my-pi.sh")
    expect(path).to include("/home/vscode/.bun/bin")
  end

  it "pins and verifies the oh-my-pi Bun runtime install" do
    expect(oh_my_pi_installer).to include('BUN_VERSION="${BUN_VERSION:-1.3.14}"')
    expect(oh_my_pi_installer).to include("SHASUMS256.txt")
    expect(oh_my_pi_installer).to include("sha256sum -c -")
    expect(oh_my_pi_installer).not_to include("https://bun.sh/install")
  end

  it "re-runs setup on every start to restore the detached dev supervisor" do
    command = devcontainer.fetch("postStartCommand")

    expect(command).to include("git config --local remote.origin.url https://github.com/viamin/paid.git")
    expect(command).to include("git config --local credential.helper '!/usr/bin/gh auth git-credential'")
    expect(command).to include("bash .devcontainer/ensure-networks-and-qdrant.sh && bin/setup")
  end
end
