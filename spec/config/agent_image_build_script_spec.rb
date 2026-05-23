# frozen_string_literal: true

require "rails_helper"

class AgentImageBuildScript < Pathname
end

class AgentImageWorkflow < Pathname
end

RSpec.describe AgentImageBuildScript, :no_db do
  describe "build script" do
    subject(:script_source) { Rails.root.join("scripts/build-agent-image.sh").read }

    it "uses the renamed runner install-contract extractor consistently" do
      expect(script_source).to include("scripts/extract-runner-install-contract.rb")
      expect(script_source).not_to include("scripts/extract-provider-install-contract.rb")
    end

    it "extracts the Bundler version from Gemfile.lock for the agent build" do
      expect(script_source).to include("BUNDLER_VERSION=$(awk '/^BUNDLED WITH$/{getline; gsub(/^ +/, \"\", $0); print $0}'")
      expect(script_source).to include('--build-arg "BUNDLER_VERSION=${BUNDLER_VERSION}"')
    end
  end

  describe AgentImageWorkflow do
    subject(:workflow_source) { Rails.root.join(".github/workflows/agent-image.yml").read }

    it "compares extracted lockfile contract versions instead of grepping zero-context diffs" do
      expect(workflow_source).to include('previous_bundler_version=$(extract_lockfile_bundler_version "${BASE_SHA}")')
      expect(workflow_source).to include('current_bundler_version=$(extract_lockfile_bundler_version "${HEAD_SHA}")')
      expect(workflow_source).to include('bundler: ${previous_bundler_version:-missing} -> ${current_bundler_version:-missing}\n')
      expect(workflow_source).not_to include('| grep -E')
    end
  end
end
