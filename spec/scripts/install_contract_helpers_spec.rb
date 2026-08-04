# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("scripts/lib/install_contract_helpers")

RSpec.describe InstallContractHelpers, :no_db do
  describe ".normalized_install_command" do
    it "adds ignore-scripts to plain npm installs" do
      contract = { install_command: [ "npm", "install", "-g", "codex@latest" ] }

      command = described_class.normalized_install_command(contract)

      expect(command).to eq([ "npm", "install", "-g", "codex@latest", "--ignore-scripts" ])
    end

    it "appends the trusted postinstall step when the contract requires it" do
      contract = {
        install_command: [ "npm", "install", "-g", "opencode-ai@latest" ],
        package: "opencode-ai",
        requires_postinstall: true,
        postinstall_command: "node $(npm root -g)/opencode-ai/postinstall.mjs"
      }

      command = described_class.normalized_install_command(contract)

      expect(command).to eq([
        "npm", "install", "-g", "opencode-ai@latest", "--ignore-scripts",
        "&&", "node", "$(npm", "root", "-g)/opencode-ai/postinstall.mjs"
      ])
    end
  end
end
