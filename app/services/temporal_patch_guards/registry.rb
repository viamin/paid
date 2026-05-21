# frozen_string_literal: true

require "date"
require "yaml"

module TemporalPatchGuards
  Entry = Data.define(:name, :workflow_type, :introduced_on) do
    def sunset_at
      introduced_on.next_day.beginning_of_day.utc
    end
  end

  class Registry
    METADATA_PATH = Rails.root.join("config/temporal_patch_guards.yml")

    class << self
      def entries
        load_entries.freeze
      end

      def workflow_types
        entries.map(&:workflow_type).uniq
      end

      private

      def load_entries
        data = YAML.safe_load(METADATA_PATH.read, aliases: false) || {}

        data.fetch("workflows", {}).flat_map do |workflow_type, guards|
          guards.map do |guard_name, metadata|
            Entry.new(
              name: guard_name,
              workflow_type: workflow_type,
              introduced_on: Date.iso8601(metadata.fetch("introduced_on"))
            )
          end
        end.sort_by { |entry| [ entry.workflow_type, entry.introduced_on, entry.name ] }
      end
    end
  end
end
