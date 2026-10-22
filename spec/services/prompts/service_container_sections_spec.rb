# frozen_string_literal: true

require "rails_helper"

RSpec.describe Prompts::ServiceContainerSections do # @spec POLYGLOT-TEST-011
  describe ".render_available_services_intro_result" do
    let(:project) { create(:project) }

    it "keeps the attempted slug in fallback provenance" do
      Prompt.find_by(slug: described_class::AVAILABLE_SERVICES_INTRO_SLUG)&.destroy!

      result = described_class.render_available_services_intro_result(project: project)

      expect(result.prompt_provenance).to include(
        slug: described_class::AVAILABLE_SERVICES_INTRO_SLUG,
        prompt_id: nil,
        prompt_version_id: nil,
        version_number: nil,
        source: "fallback"
      )
    end
  end

  describe ".has_database_container?" do
    let(:project) { create(:project) }
    let(:postgres_image) { "postgres:16" }
    let(:postgres_container) do
      create(:service_container, account: project.account, image: postgres_image, name: "postgres", port: 5432, status: "running")
    end

    it "returns true when the project is configured with a running postgres container" do
      create(:project_service_container, project: project, service_container: postgres_container)

      expect(described_class.has_database_container?(project: project)).to be(true)
    end

    it "returns false when the project has no postgres containers" do
      redis_container = create(:service_container, :redis, account: project.account, status: "running")
      create(:project_service_container, project: project, service_container: redis_container)

      expect(described_class.has_database_container?(project: project)).to be(false)
    end

    it "returns true when the agent_run lists a running postgres container" do
      agent_run = create(:agent_run, project: project, service_container_ids: [ postgres_container.id ])

      expect(described_class.has_database_container?(project: project, agent_run: agent_run)).to be(true)
    end

    it "returns false when the agent_run's listed containers are not running" do
      stopped_container = create(:service_container, account: project.account, image: postgres_image, status: "stopped")
      agent_run = create(:agent_run, project: project, service_container_ids: [ stopped_container.id ])

      expect(described_class.has_database_container?(project: project, agent_run: agent_run)).to be(false)
    end

    it "does not fall back to project config when the agent_run has no provisioned services" do
      create(:project_service_container, project: project, service_container: postgres_container)
      agent_run = create(:agent_run, project: project, service_container_ids: [])

      expect(described_class.has_database_container?(project: project, agent_run: agent_run)).to be(false)
    end

    it "returns false when the configured postgres container is stopped" do
      stopped_container = create(:service_container, account: project.account, image: postgres_image, status: "stopped")
      create(:project_service_container, project: project, service_container: stopped_container)

      expect(described_class.has_database_container?(project: project)).to be(false)
      expect(described_class.service_environment_section_for(project: project)).to include("Environment Constraints")
    end

    it "returns false when the agent_run is nil and the project has no containers" do
      expect(described_class.has_database_container?(project: project, agent_run: nil)).to be(false)
    end

    it "returns false when the project is nil" do
      expect(described_class.has_database_container?(project: nil)).to be(false)
    end
  end
end
