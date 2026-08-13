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

      runner_pattern = /\\A(?<class>Screenshots::SeedData::[A-Z]\\w*(?:::[A-Z]\\w*)*)\\.call\\z/

      serialize_seed_value = lambda do |value|
        case value
        when String, Numeric, TrueClass, FalseClass, NilClass
          value
        else
          return value.iso8601 if value.respond_to?(:iso8601)

          :__screenshots_skip__
        end
      end

      capture_seed_result = lambda do |record|
        next record unless record.respond_to?(:attributes)

        record.attributes.each_with_object({}) do |(attribute, value), captured|
          serialized = serialize_seed_value.call(value)
          captured[attribute] = serialized unless serialized == :__screenshots_skip__
        end
      end

      resolve_seed_value = lambda do |value, seed_records|
        case value
        when Hash
          value.transform_values { |nested| resolve_seed_value.call(nested, seed_records) }
        when Array
          value.map { |nested| resolve_seed_value.call(nested, seed_records) }
        when String
          seed_records.fetch(value, value)
        else
          value
        end
      end

      resolve_seed_attributes = lambda do |attributes, seed_records|
        attributes.to_h.transform_values { |value| resolve_seed_value.call(value, seed_records) }
      end

      execute_seed_runner = lambda do |reference|
        match = runner_pattern.match(reference)
        raise ArgumentError, "seed runner must reference Screenshots::SeedData::<Runner>.call" unless match

        runner_class = match[:class].safe_constantize
        raise ArgumentError, "seed runner \#{reference} could not be resolved" unless runner_class

        callable = runner_class.method(:call)

        unless callable.arity.zero?
          raise ArgumentError, "seed runner \#{reference} must accept zero arguments"
        end

        runner_class.call
      end

      with_seed_context = lambda do |&block|
        return block.call unless defined?(TenantContext)

        TenantContext.with_system_access { block.call }
      end

      with_seed_context.call do
        seed.each do |entry|
          key = entry.fetch("key")

          if entry["runner"].present?
            result = execute_seed_runner.call(entry.fetch("runner"))
            if key == "__all__" && result.is_a?(Hash)
              result.each do |rk, rv|
                seed_records[rk.to_s] = rv
                results[rk] = rv.respond_to?(:attributes) ? capture_seed_result.call(rv) : rv
              end
            else
              seed_records[key] = result
              results[key] = result.respond_to?(:attributes) ? capture_seed_result.call(result) : result
            end
            next
          end

          attributes = resolve_seed_attributes.call(entry["attributes"], seed_records)

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
          results[key] = capture_seed_result.call(record)
        end
      end

      puts JSON.generate(results)
    RUBY

    # Runs the seed script and returns parsed seed data keyed by record name.
    #
    # The cuprite (in-process) screenshot path runs seeds locally against
    # +repo_path+ via +bin/rails runner+. Container capture supplies an
    # +executor+ that runs the same script inside the screenshot container
    # so seeds load into the per-run isolated database before the app starts.
    #
    # executor - optional callable invoked as +executor.call(env)+ that returns
    #            +[stdout, stderr, success]+. When omitted, seeds run locally
    #            and only for the cuprite driver (or when +force+ is true).
    def call(config:, repo_path:, driver_name:, force: false, executor: nil)
      return {} if config.seed.empty?
      return {} if !force && executor.nil? && driver_name != "cuprite"

      env = seed_env(config)
      stdout, stderr, success = executor ? executor.call(env) : run_locally(env, repo_path)

      raise "Screenshot seed setup failed: #{stderr.presence || stdout}" unless success

      parse_output(stdout)
    rescue JSON::ParserError => e
      raise "Screenshot seed setup returned invalid JSON: #{e.message}"
    end

    private

    def seed_env(config)
      { "SCREENSHOT_SEED_CONFIG" => JSON.generate(config.seed.map(&:to_h)) }
    end

    def run_locally(env, repo_path)
      stdout, stderr, status = Open3.capture3(env, "bin/rails", "runner", SCRIPT, chdir: repo_path)
      [ stdout, stderr, status.success? ]
    end

    def parse_output(stdout)
      JSON.parse(stdout).transform_keys(&:to_sym).transform_values do |value|
        value.is_a?(Hash) ? OpenStruct.new(value) : value
      end
    end
  end
end
