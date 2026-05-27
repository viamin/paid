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

  it "installs opencode through the shared contract wrapper" do
    command = devcontainer.fetch("postCreateCommand").fetch("opencode")

    expect(command).to eq("bash scripts/install-from-contract.sh opencode")
  end
end
