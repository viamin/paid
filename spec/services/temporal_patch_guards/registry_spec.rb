# frozen_string_literal: true

require "rails_helper"

RSpec.describe TemporalPatchGuards::Registry do
  describe ".entries" do
    it "tracks every Temporal patch guard still present in workflow code" do
      workflow_guards = Dir.glob(Rails.root.join("app/temporal/workflows/*.rb")).flat_map do |path|
        content = File.read(path)
        workflow_name = content[/class\s+(\w+)\s+<\s+BaseWorkflow/, 1]
        next [] unless workflow_name

        content.scan(/Temporalio::Workflow\.patched\("([^"]+)"\)/).flatten.map do |guard_name|
          [ "Workflows::#{workflow_name}", guard_name ]
        end
      end.uniq.sort

      registry_guards = described_class.entries.map { |entry| [ entry.workflow_type, entry.name ] }.sort

      expect(registry_guards).to eq(workflow_guards)
    end

    it "parses ISO dates for every entry" do
      expect(described_class.entries).to all(have_attributes(introduced_on: be_a(Date)))
    end
  end

  describe TemporalPatchGuards::Entry do
    describe "#sunset_at" do
      it "returns the next UTC midnight regardless of the Rails time zone" do
        Time.use_zone("Eastern Time (US & Canada)") do
          entry = described_class.new(
            name: "guard-a",
            workflow_type: "Workflows::GitHubPollWorkflow",
            introduced_on: Date.new(2026, 4, 20)
          )

          expect(entry.sunset_at).to eq(Time.utc(2026, 4, 21))
        end
      end
    end
  end
end
