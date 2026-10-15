# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketplaceEntryVersion do
  describe "validations" do
    it "rejects renderer payloads that are not objects" do
      version = build(:marketplace_entry_version, renderers: { "claude" => "oops" })

      expect(version).not_to be_valid
      expect(version.errors[:renderers]).to include("must map provider keys to objects (invalid: claude)")
    end

    it "accepts a conforming tool canonical artifact" do # @spec TOOL-SIDECAR-001
      entry = build(:marketplace_entry, entry_type: "tool")
      version = build(:marketplace_entry_version,
        marketplace_entry: entry,
        canonical_artifact: {
          "install_type" => "tool",
          "image" => "acme/search:1.0",
          "port" => 8080,
          "env" => { "SEARCH_TOKEN" => "configured-at-runtime" },
          "alias" => "search",
          "hardening" => { "readonly_rootfs" => true }
        })

      expect(version).to be_valid
    end

    [
      [ {}, "install_type must be \"tool\"" ],
      [ { "install_type" => "docker_image", "image" => "acme/search:1.0", "port" => 8080 }, "install_type must be \"tool\"" ],
      [ { "install_type" => "tool", "port" => 8080 }, "image must be a non-empty string" ],
      [ { "install_type" => "tool", "image" => "acme/search:1.0", "port" => "8080" }, "port must be an integer between 1 and 65535" ],
      [ { "install_type" => "tool", "image" => "acme/search:1.0", "port" => 8080, "env" => [] }, "env must be an object" ],
      [ { "install_type" => "tool", "image" => "acme/search:1.0", "port" => 8080, "alias" => 12 }, "alias must be a non-empty string" ],
      [ { "install_type" => "tool", "image" => "acme/search:1.0", "port" => 8080, "hardening" => [] }, "hardening must be an object" ]
    ].each do |artifact, message|
      it "rejects a tool canonical artifact when #{message}" do # @spec TOOL-SIDECAR-001
        entry = build(:marketplace_entry, entry_type: "tool")
        version = build(:marketplace_entry_version, marketplace_entry: entry, canonical_artifact: artifact)

        expect(version).not_to be_valid
        expect(version.errors[:canonical_artifact]).to include(message)
      end
    end
  end

  describe "#destroy" do
    it "prevents deleting versions that have been attached to agent runs" do
      entry = create(:marketplace_entry)
      version = create(:marketplace_entry_version, marketplace_entry: entry)
      entry.update!(current_version: version)
      agent_run = create(:agent_run, project: create(:project, account: entry.account))
      create(:agent_run_marketplace_entry,
        agent_run: agent_run,
        marketplace_entry: entry,
        marketplace_entry_version: version)

      expect(version.destroy).to be(false)
      expect(version.errors[:base]).to include("cannot delete marketplace entry versions that have been attached to agent runs")
      expect(described_class.exists?(version.id)).to be(true)
    end
  end
end
