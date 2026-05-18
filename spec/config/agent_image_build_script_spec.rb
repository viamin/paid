# frozen_string_literal: true

require "rails_helper"

class AgentImageBuildScript < Pathname
end

RSpec.describe AgentImageBuildScript, :no_db do
  subject(:script_source) { Rails.root.join("scripts/build-agent-image.sh").read }

  it "uses the renamed runner install-contract extractor consistently" do
    expect(script_source).to include("scripts/extract-runner-install-contract.rb")
    expect(script_source).not_to include("scripts/extract-provider-install-contract.rb")
  end
end
