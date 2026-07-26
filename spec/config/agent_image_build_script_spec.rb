# frozen_string_literal: true

require "rails_helper"

class AgentImageBuildScript < Pathname
end

class AgentImageWorkflow < Pathname
end

class AgentImageDockerfile < Pathname
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

  describe AgentImageDockerfile do
    subject(:dockerfile_source) { Rails.root.join("docker/agent/Dockerfile").read }

    it "installs the oh-my-pi Bun runtime into a non-root shared path" do
      expect(dockerfile_source).to include('export BUN_INSTALL="/usr/local/bun"')
      expect(dockerfile_source).to include('ln -sf "${BUN_INSTALL}/bin/omp" /usr/local/bin/omp')
      expect(dockerfile_source).to include('ln -sf "${BUN_INSTALL}/bin/bun" /usr/local/bin/bun')
      expect(dockerfile_source).not_to include('ln -sf /root/.bun/bin/omp /usr/local/bin/omp')
      expect(dockerfile_source).not_to include('ln -sf /root/.bun/bin/bun /usr/local/bin/bun')
    end
  end
end
