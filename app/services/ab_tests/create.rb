# frozen_string_literal: true

module AbTests
  # Creates an A/B test for a prompt with a control version and up to 3 variants.
  #
  # @example
  #   AbTests::Create.call(
  #     prompt: prompt,
  #     name: "Improve coding prompt v2",
  #     variant_version_ids: [version2.id, version3.id]
  #   )
  class Create
    attr_reader :prompt, :name, :description, :variant_version_ids, :options

    def initialize(prompt:, name:, variant_version_ids:, description: nil, **options)
      @prompt = prompt
      @name = name
      @description = description
      @variant_version_ids = variant_version_ids
      @options = options
    end

    def self.call(...)
      new(...).create
    end

    def create
      validate!

      ActiveRecord::Base.transaction do
        test = AbTest.create!(
          prompt: prompt,
          name: name,
          description: description,
          status: "draft",
          control_version_id: prompt.current_version_id,
          min_samples_per_variant: options.fetch(:min_samples_per_variant, 30),
          confidence_threshold: options.fetch(:confidence_threshold, 0.95)
        )

        test.ab_test_variants.create!(
          prompt_version: prompt.current_version,
          is_control: true
        )

        variant_version_ids.each do |version_id|
          version = prompt.prompt_versions.find(version_id)
          test.ab_test_variants.create!(
            prompt_version: version,
            is_control: false
          )
        end

        test
      end
    end

    private

    def validate!
      raise ArgumentError, "prompt must have a current version" unless prompt.current_version_id
      raise ArgumentError, "at least one variant version is required" if variant_version_ids.empty?
      raise ArgumentError, "maximum #{AbTest::MAX_VARIANTS} variants allowed" if variant_version_ids.size > AbTest::MAX_VARIANTS
      raise ArgumentError, "variant versions must be unique" if variant_version_ids.uniq.size != variant_version_ids.size
      raise ArgumentError, "variant versions cannot include the control version" if variant_version_ids.include?(prompt.current_version_id)
      raise ArgumentError, "prompt already has a running A/B test" if prompt.ab_tests.running.exists?
      validate_variant_versions_exist!
    end

    def validate_variant_versions_exist!
      existing_ids = prompt.prompt_versions.where(id: variant_version_ids).pluck(:id)
      missing_ids = variant_version_ids - existing_ids
      return if missing_ids.empty?

      raise ArgumentError, "variant version(s) #{missing_ids.join(', ')} not found for this prompt"
    end
  end
end
