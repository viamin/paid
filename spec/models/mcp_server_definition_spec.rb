# frozen_string_literal: true

require "rails_helper"

RSpec.describe McpServerDefinition do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to have_many(:project_mcp_servers).dependent(:destroy) }
    it { is_expected.to have_many(:projects).through(:project_mcp_servers) }
  end

  describe "validations" do
    subject { build(:mcp_server_definition) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_uniqueness_of(:name).scoped_to(:account_id) }
    it { is_expected.to validate_presence_of(:transport) }
    it { is_expected.to validate_inclusion_of(:transport).in_array(described_class::TRANSPORTS) }
    it { is_expected.to validate_presence_of(:install_type) }
    it { is_expected.to validate_inclusion_of(:install_type).in_array(described_class::INSTALL_TYPES) }
    it { is_expected.to validate_length_of(:command).is_at_most(500) }
    it { is_expected.to validate_length_of(:url).is_at_most(2048) }
    it { is_expected.to validate_length_of(:image).is_at_most(500) }

    describe "npx install type" do
      it "requires command" do
        definition = build(:mcp_server_definition, install_type: "npx", command: nil)
        expect(definition).not_to be_valid
        expect(definition.errors[:command]).to include("is required for npx install type")
      end

      it "forbids image" do
        definition = build(:mcp_server_definition, install_type: "npx", image: "some-image:latest")
        expect(definition).not_to be_valid
        expect(definition.errors[:image]).to include("is not allowed for npx install type")
      end

      it "is valid with command and no image" do
        definition = build(:mcp_server_definition, install_type: "npx", command: "npx-server", image: nil)
        expect(definition).to be_valid
      end
    end

    describe "docker_image install type" do
      it "requires image" do
        definition = build(:mcp_server_definition, :docker, image: nil)
        expect(definition).not_to be_valid
        expect(definition.errors[:image]).to include("is required for docker_image install type")
      end

      it "is valid with image" do
        definition = build(:mcp_server_definition, :docker, image: "mcp/server:latest")
        expect(definition).to be_valid
      end
    end

    describe "sse transport" do
      it "requires url" do
        definition = build(:mcp_server_definition, :docker_sse, url: nil)
        expect(definition).not_to be_valid
        expect(definition.errors[:url]).to include("is required for sse transport")
      end

      it "is valid with url" do
        definition = build(:mcp_server_definition, :docker_sse, url: "http://localhost:3001/sse")
        expect(definition).to be_valid
      end
    end
  end

  describe "scopes" do
    it "returns only enabled definitions" do
      account = create(:account)
      enabled = create(:mcp_server_definition, account: account)
      create(:mcp_server_definition, :disabled, account: account)

      expect(described_class.enabled).to eq([ enabled ])
    end
  end

  describe "#to_snapshot" do
    it "returns a hash representation for snapshotting" do
      definition = build(:mcp_server_definition,
        name: "fs-server",
        transport: "stdio",
        install_type: "npx",
        command: "@modelcontextprotocol/server-filesystem",
        args: [ "/workspace" ],
        env: { "KEY" => "value" },
        metadata: { "version" => "1.0" })

      snapshot = definition.to_snapshot

      expect(snapshot).to eq(
        "name" => "fs-server",
        "transport" => "stdio",
        "install_type" => "npx",
        "command" => "@modelcontextprotocol/server-filesystem",
        "args" => [ "/workspace" ],
        "env" => { "KEY" => "value" },
        "metadata" => { "version" => "1.0" }
      )
    end

    it "excludes blank values" do
      definition = build(:mcp_server_definition,
        url: nil,
        image: nil,
        env: {},
        metadata: {})

      snapshot = definition.to_snapshot

      expect(snapshot).not_to have_key("url")
      expect(snapshot).not_to have_key("image")
      expect(snapshot).not_to have_key("env")
      expect(snapshot).not_to have_key("metadata")
    end
  end
end
