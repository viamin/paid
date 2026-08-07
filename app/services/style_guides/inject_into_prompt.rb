# frozen_string_literal: true

module StyleGuides
  # Injects compressed style guide content into an agent prompt.
  # Resolves applicable style guides for the project and appends them.
  #
  # @example
  #   full_prompt = StyleGuides::InjectIntoPrompt.call(
  #     prompt: base_prompt,
  #     project: project
  #   )
  class InjectIntoPrompt
    # Total byte budget (in bytes) for all injected style guide section contents
    # combined. This limit applies only to the per-guide sections returned by
    # `format_guide` and does not include the static wrapper/header or join
    # separators added by `style_guide_section`. Guides are prioritized by
    # specificity (project > account > global); once the budget is exhausted,
    # remaining guides are omitted.
    # Default total byte budget for injected style guide sections.
    # Overridden by UserSetting#style_guide_max_total_bytes at runtime.
    DEFAULT_MAX_TOTAL_BYTES = 32_000

    attr_reader :prompt, :project, :agent_run, :source

    def initialize(prompt:, project:, agent_run: nil, source: nil)
      @prompt = prompt
      @project = project
      @agent_run = agent_run
      @source = source || self.class.name.demodulize
    end

    def self.call(...)
      new(...).call
    end

    def call
      guides = StyleGuide.resolve_for(project).to_a
      return prompt if guides.empty?

      selected_guides = collect_sections_within_budget(guides)
      sections = selected_guides.map { |entry| entry[:section] }
      return prompt if sections.empty?

      record_exposures!(selected_guides)

      combined_prompt = "#{prompt}\n#{style_guide_section(sections)}"
      combined_prompt.delete("\x00")
    end

    private

    def collect_sections_within_budget(guides)
      budget = max_total_bytes
      total_bytes = 0
      guides.filter_map do |guide|
        resolved = resolve_guide_version(guide)
        section = format_guide(guide, resolved[:version])
        next if section.nil?
        next if total_bytes + section.bytesize > budget

        total_bytes += section.bytesize
        resolved.merge(guide:, section:)
      end
    end

    def max_total_bytes
      settings = AgentRuns::UserSettingsResolver.call(project: project, strict: false)
      settings&.style_guide_max_total_bytes || DEFAULT_MAX_TOTAL_BYTES
    end

    def style_guide_section(sections)
      <<~SECTION

        # Style Guide

        Follow these coding conventions for this project:

        #{sections.join("\n\n")}
      SECTION
    end

    def format_guide(guide, version)
      label =
        if guide.project_level?
          "(project)"
        elsif guide.account_level?
          "(account)"
        else
          "(global)"
        end
      content = version&.content_for_prompt(project: project) || guide.content_for_prompt
      return if content.blank?

      "## #{guide.name} #{label}\n\n#{content}"
    end

    # @spec STYLE-GUIDE-EVOLUTION-004
    def resolve_guide_version(guide)
      assignment = existing_assignment_for(guide) || assign_running_ab_test_for(guide)
      version = assignment&.style_guide_ab_test_variant&.style_guide_version || guide.current_version
      version ||= build_fallback_version_for(guide)
      { version:, assignment: }
    end

    def build_fallback_version_for(guide)
      guide.style_guide_versions.order(version: :desc).first
    end

    def existing_assignment_for(guide)
      return nil unless agent_run

      StyleGuideAbTestAssignment
        .joins(:style_guide_ab_test)
        .includes(style_guide_ab_test_variant: :style_guide_version)
        .where(agent_run:, style_guide_ab_tests: { style_guide_id: guide.id })
        .order(:id)
        .first
    end

    def assign_running_ab_test_for(guide)
      return nil unless agent_run

      ab_test = StyleGuideAbTest.running.find_by(account: project.account, style_guide: guide)
      return nil unless ab_test

      StyleGuideAbTests::Assign.call(style_guide_ab_test: ab_test, agent_run: agent_run)
    end

    # @spec STYLE-GUIDE-EVOLUTION-003
    def record_exposures!(selected_guides)
      return unless agent_run

      selected_guides.each_with_index do |entry, index|
        guide = entry[:guide]
        version = entry[:version]
        assignment = entry[:assignment]

        exposure = StyleGuideRunExposure.find_or_initialize_by(agent_run: agent_run, guide_name: guide.name)
        exposure.style_guide = guide
        exposure.style_guide_version = version
        exposure.style_guide_ab_test_assignment = assignment
        exposure.source_scope = source_scope_for(guide)
        exposure.position = index
        exposure.injected_via = source
        exposure.injected_content = version&.content_for_prompt(project: project) || guide.content_for_prompt
        exposure.save!
      end
    end

    def source_scope_for(guide)
      return "project" if guide.project_level?
      return "account" if guide.account_level?

      "global"
    end
  end
end
