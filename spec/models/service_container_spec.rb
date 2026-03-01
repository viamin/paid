# frozen_string_literal: true

require "rails_helper"

RSpec.describe ServiceContainer do
  describe "associations" do
    it { is_expected.to have_many(:project_service_containers).dependent(:destroy) }
    it { is_expected.to have_many(:projects).through(:project_service_containers) }
  end

  describe "validations" do
    subject { build(:service_container) }

    it { is_expected.to validate_presence_of(:image) }
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_uniqueness_of(:name) }
    it { is_expected.to validate_presence_of(:port) }

    it { is_expected.to validate_numericality_of(:port).only_integer.is_greater_than(0).is_less_than(65_536) }

    it "validates status inclusion" do
      container = build(:service_container, status: "invalid")
      expect(container).not_to be_valid
      expect(container.errors[:status]).to be_present
    end

    it "validates image is in allowlist" do
      admin = create(:user, :admin)
      create(:user_setting, user: admin, allowed_service_images: [ "postgres:16" ])
      container = build(:service_container, image: "malicious:latest")
      expect(container).not_to be_valid
      expect(container.errors[:image]).to include("is not in the allowed service images list")
    end

    it "allows images in the allowlist" do
      admin = create(:user, :admin)
      create(:user_setting, user: admin, allowed_service_images: [ "postgres:16" ])
      container = build(:service_container, image: "postgres:16")
      expect(container).to be_valid
    end
  end

  describe "scopes" do
    it ".running returns only running containers" do
      running = create(:service_container, :running)
      create(:service_container, status: "stopped")

      expect(described_class.running).to eq([ running ])
    end

    it ".stopped returns only stopped containers" do
      create(:service_container, :running)
      stopped = create(:service_container, status: "stopped")

      expect(described_class.stopped).to eq([ stopped ])
    end
  end

  describe "#running?" do
    it "returns true when status is running" do
      container = build(:service_container, status: "running")
      expect(container.running?).to be true
    end

    it "returns false when status is not running" do
      container = build(:service_container, status: "stopped")
      expect(container.running?).to be false
    end
  end

  describe "#active_agent_run_count" do
    it "counts active agent runs referencing this container" do
      service_container = create(:service_container)
      project = create(:project)
      create(:project_service_container, project: project, service_container: service_container)

      issue = create(:issue, project: project)
      create(:agent_run, :running, project: project, issue: issue,
        service_container_ids: [ service_container.id ])
      create(:agent_run, :completed, project: project, issue: issue,
        service_container_ids: [ service_container.id ])

      expect(service_container.active_agent_run_count).to eq(1)
    end

    it "returns 0 when no active runs reference this container" do
      service_container = create(:service_container)
      expect(service_container.active_agent_run_count).to eq(0)
    end
  end
end
