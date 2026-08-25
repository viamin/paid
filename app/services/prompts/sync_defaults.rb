# frozen_string_literal: true

module Prompts
  class SyncDefaults
    Result = Data.define(:prompts_created, :versions_created, :unchanged)

    LOCK_NAMESPACE = 1_357_180_004
    LOCK_KEY = 1
    ADVISORY_LOCK_SQL = "SELECT pg_advisory_xact_lock(#{LOCK_NAMESPACE}, #{LOCK_KEY})".freeze

    def self.call(...)
      new(...).call
    end

    def initialize(definitions:)
      @definitions = definitions
      @counts = { prompts_created: 0, versions_created: 0, unchanged: 0 }
    end

    # @spec PROMPT-DEFAULT-SYNC-001, PROMPT-DEFAULT-SYNC-002,
    #   PROMPT-DEFAULT-SYNC-003, PROMPT-DEFAULT-SYNC-004
    def call
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        TenantContext.with_system_access do
          Prompt.transaction(requires_new: true) do
            connection.execute(ADVISORY_LOCK_SQL)
            definitions.each { |definition| synchronize(definition) }
          end
        end
      end

      Result.new(**counts).tap { |result| log_result(result) }
    end

    private

    attr_reader :definitions, :counts

    def synchronize(definition)
      prompt = Prompt.global.find_or_initialize_by(slug: definition.fetch(:slug))
      record_prompt_creation(prompt)
      apply_metadata(prompt, definition)
      synchronize_version(prompt, definition)
    end

    def record_prompt_creation(prompt)
      counts[:prompts_created] += 1 if prompt.new_record?
    end

    def apply_metadata(prompt, definition)
      if prompt.new_record?
        prompt.assign_attributes(definition.slice(:name, :description, :category).merge(active: true))
      else
        prompt.name ||= definition.fetch(:name)
        prompt.description ||= definition.fetch(:description)
        prompt.category ||= definition.fetch(:category)
        prompt.active = true if prompt.active.nil?
      end
      prompt.save!
    end

    def synchronize_version(prompt, definition)
      if current_definition?(prompt.current_version, definition)
        counts[:unchanged] += 1
        return
      end

      prompt.create_version!(
        template: definition.fetch(:template),
        variables: definition.fetch(:variables),
        created_by: "seed",
        change_notes: change_notes(prompt)
      )
      counts[:versions_created] += 1
    end

    def current_definition?(version, definition)
      version && normalize(version.template) == normalize(definition.fetch(:template)) &&
        version.variables == definition.fetch(:variables)
    end

    def normalize(template)
      template.to_s.strip
    end

    def change_notes(prompt)
      return "Initial version from seeds" if prompt.current_version.nil?

      "Updated from seeds: template and/or variables changed"
    end

    def log_result(result)
      Rails.logger.info(
        message: "prompt_defaults.sync_completed",
        prompts_created: result.prompts_created,
        versions_created: result.versions_created,
        unchanged: result.unchanged
      )
    end
  end
end
