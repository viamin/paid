# frozen_string_literal: true

require "json"
require "open3"
require "ostruct"

module Screenshots
  class SeedRunner
    SCRIPT = <<~RUBY
      require "json"

      seed = JSON.parse(ENV.fetch("SCREENSHOT_SEED_CONFIG"))
      seed_records = {}
      results = {}

      def capture_seed_result(record)
        return record unless record.respond_to?(:attributes)

        record.attributes.slice("id", "email", "slug", "name")
      end

      def resolve_seed_value(value, seed_records)
        case value
        when Hash
          value.transform_values { |nested| resolve_seed_value(nested, seed_records) }
        when Array
          value.map { |nested| resolve_seed_value(nested, seed_records) }
        when String
          seed_records.fetch(value, value)
        else
          value
        end
      end

      def resolve_seed_attributes(attributes, seed_records)
        attributes.to_h.transform_values { |value| resolve_seed_value(value, seed_records) }
      end

      TenantContext.with_system_access do
        seed.each do |entry|
          key = entry.fetch("key")

          if entry["runner"].present?
            result = eval(entry.fetch("runner"), TOPLEVEL_BINDING, "screenshots_seed_runner", 1)
            if key == "__all__" && result.is_a?(Hash)
              result.each do |rk, rv|
                seed_records[rk.to_s] = rv
                results[rk] = rv.respond_to?(:attributes) ? capture_seed_result(rv) : rv
              end
            else
              seed_records[key] = result
              results[key] = result.respond_to?(:attributes) ? capture_seed_result(result) : result
            end
            next
          end

          attributes = resolve_seed_attributes(entry["attributes"], seed_records)

          record = if defined?(FactoryBot) && entry["factory"].present?
            FactoryBot.create(entry.fetch("factory").to_sym, **attributes.symbolize_keys)
          else
            model_class = entry.fetch("model").constantize
            lookup = attributes.slice("id", "email", "slug", "name")
            record = lookup.any? ? model_class.find_or_initialize_by(lookup) : model_class.new
            record.assign_attributes(attributes.except(*lookup.keys))
            record.save!
            record
          end

          seed_records[key] = record
          results[key] = capture_seed_result(record)
        end
      end

      puts JSON.generate(results)
    RUBY

    def call(config:, repo_path:, driver_name:)
      return {} unless driver_name == "cuprite"
      return {} if config.seed.empty?

      stdout, stderr, status = Open3.capture3(
        { "SCREENSHOT_SEED_CONFIG" => JSON.generate(config.seed.map(&:to_h)) },
        "bin/rails",
        "runner",
        SCRIPT,
        chdir: repo_path
      )

      raise "Screenshot seed setup failed: #{stderr.presence || stdout}" unless status.success?

      JSON.parse(stdout).transform_keys(&:to_sym).transform_values do |value|
        OpenStruct.new(value)
      end
    rescue JSON::ParserError => e
      raise "Screenshot seed setup returned invalid JSON: #{e.message}"
    end
  end
end
