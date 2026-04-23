# frozen_string_literal: true

module Knowledge
  module ContextBundle
    # Builds a curated context bundle from the knowledge base for agent prompts.
    # Queries knowledge artifacts by type, formats them into markdown sections,
    # and respects a configurable token budget.
    #
    # @example
    #   result = Knowledge::ContextBundle::Build.call(
    #     issue: issue,
    #     project: project,
    #     token_budget: 4000
    #   )
    #   result[:content]       # => "## Codebase Context ..."
    #   result[:total_tokens]  # => 3847
    #   result[:sections]      # => [:routes, :symbols, :hotspots, ...]
    class Build
      DEFAULT_TOKEN_BUDGET = 4000

      # Section builders in priority order.
      # Conventions section is not yet implemented — will be added when
      # a conventions collector lands in the knowledge pipeline.
      SECTION_ORDER = %i[business_context routes symbols hotspots decisions stats].freeze

      attr_reader :issue, :project, :agent_run, :token_budget, :section_order

      # issue is accepted for future relevance-ranking of artifacts.
      # Currently unused — all active artifacts are included project-wide.
      def initialize(issue:, project:, agent_run: nil, token_budget: nil, section_order: nil)
        @issue = issue
        @project = project
        @agent_run = agent_run
        @token_budget = token_budget || experiment_value("knowledge.token_budget") || env_token_budget
        @section_order = section_order || experiment_value("knowledge.section_order") || SECTION_ORDER
      end

      def self.call(...)
        new(...).call
      end

      def call
        sections, queries_made = build_sections
        return empty_result(queries_made) if sections.empty?

        content = render(sections)
        {
          content: content,
          sections: sections.map { |s| s[:name] },
          total_tokens: estimate_tokens(content),
          queries_made: queries_made
        }
      end

      private

      def build_sections
        # Reserve tokens for the top-level heading
        header_overhead = estimate_tokens("## Codebase Context (auto-generated from knowledge base)\n")
        remaining_budget = token_budget - header_overhead
        built = []
        queries_made = 0

        section_order.each do |section_name|
          break if remaining_budget <= 0

          queries_made += 1
          section = send(:"build_#{section_name}_section")
          next if section.nil?

          # Include the heading in the token count for this section
          section_tokens = estimate_tokens("### #{section[:heading]}\n#{section[:content]}")
          if section_tokens <= remaining_budget
            built << section
            remaining_budget -= section_tokens
          else
            truncated = truncate_section(section, remaining_budget)
            if truncated
              truncated_tokens = estimate_tokens("### #{truncated[:heading]}\n#{truncated[:content]}")
              next if truncated_tokens <= 0

              built << truncated
              remaining_budget -= truncated_tokens
              break if remaining_budget <= 0
            end
          end
        end

        [ built, queries_made ]
      end

      def build_business_context_section
        artifacts = active_artifacts("business_context")
        return nil if artifacts.empty?

        lines = artifacts.map do |a|
          section_title = a.metadata&.dig("section_title") || a.identifier
          chunks = a.active_ordered_chunks.to_a
          if chunks.any?
            chunk_lines = chunks.map { |c| "- #{c.content.gsub("\n", " ").truncate(200)}" }
            "#### #{section_title}\n#{chunk_lines.join("\n")}"
          else
            "#### #{section_title}\n- #{a.content.to_s.truncate(300)}"
          end
        end

        { name: :business_context, heading: "Business Context (maintainer-provided)", content: lines.join("\n\n") }
      end

      def build_routes_section
        artifacts = active_artifacts("route")
        return nil if artifacts.empty?

        lines = artifacts.map do |a|
          "- #{a.content.presence || a.identifier}"
        end

        { name: :routes, heading: "Relevant Routes", content: lines.join("\n") }
      end

      def build_symbols_section
        artifacts = active_artifacts("symbol")
        return nil if artifacts.empty?

        lines = artifacts.map do |a|
          description = a.content.to_s.truncate(120)
          "- #{a.identifier} #{description}".strip
        end

        { name: :symbols, heading: "Related Code", content: lines.join("\n") }
      end

      def build_hotspots_section
        artifacts = active_artifacts("churn_hotspot")
        return nil if artifacts.empty?

        # Artifacts are already sorted by rank/revisions and limited to 10
        # in active_artifacts via SQL ordering.
        lines = artifacts.map do |a|
          revisions = a.metadata&.dig("revisions") || a.metadata&.dig("revision_count")
          path = a.scope_path || a.identifier
          if revisions
            "- `#{path}` is a high-churn file (#{revisions} revisions). Changes need careful review."
          else
            "- `#{path}` is a high-churn file. Changes need careful review."
          end
        end

        { name: :hotspots, heading: "Hotspot Warning", content: lines.join("\n") }
      end

      def build_decisions_section
        records = DecisionRecord.for_project(project)
                                .where(status: %w[active draft])
                                .order(created_at: :desc)
                                .limit(10)
                                .to_a
        return nil if records.empty?

        lines = records.map do |dr|
          status_label = dr.status == "active" ? "active" : "draft"
          date = dr.created_at.strftime("%Y-%m-%d")
          "- DR: \"#{dr.title}\" (#{status_label}, #{date})"
        end

        { name: :decisions, heading: "Recent Decisions", content: lines.join("\n") }
      end

      def build_stats_section
        artifacts = active_artifacts("language_stat")
        return nil if artifacts.empty?

        lines = artifacts.map do |a|
          loc = a.metadata&.dig("code") || a.metadata&.dig("loc")
          files = a.metadata&.dig("files") || a.metadata&.dig("file_count")
          lang = a.identifier || a.metadata&.dig("language")
          parts = [ lang ]
          parts << "(#{loc} LOC across #{files} files)" if loc && files
          "- #{parts.join(" ")}"
        end

        { name: :stats, heading: "Project Stats", content: lines.join("\n") }
      end

      def active_artifacts(type)
        scope = KnowledgeArtifact
          .for_project(project)
          .active
          .by_type(type)

        if type == "business_context"
          scope
            .includes(:knowledge_chunks)
            .order(:identifier)
            .limit(20)
            .to_a
        elsif type == "churn_hotspot"
          # Order by hotspot rank (lower = hotter), with nulls last, then by
          # revision count descending for ties. Limit in SQL to avoid loading
          # unbounded rows on large repos — build_hotspots_section takes the
          # top 10, so 10 is sufficient here.
          scope
            .order(
              Arel.sql("CASE WHEN metadata->>'rank' IS NULL THEN 1 ELSE 0 END"),
              Arel.sql("(metadata->>'rank')::int"),
              Arel.sql("COALESCE((metadata->>'revisions')::int, (metadata->>'revision_count')::int, 0) DESC")
            )
            .limit(10)
            .to_a
        else
          scope
            .order(:identifier)
            .limit(20)
            .to_a
        end
      end

      def render(sections)
        parts = [ "## Codebase Context (auto-generated from knowledge base)\n" ]
        sections.each do |section|
          parts << "### #{section[:heading]}\n#{section[:content]}"
        end
        parts.join("\n\n")
      end

      def truncate_section(section, budget)
        lines = section[:content].split("\n")
        truncated_lines = []
        tokens_used = estimate_tokens("### #{section[:heading]}\n")

        lines.each do |line|
          line_tokens = estimate_tokens(line)
          break if tokens_used + line_tokens > budget

          truncated_lines << line
          tokens_used += line_tokens
        end

        return nil if truncated_lines.empty?

        { name: section[:name], heading: section[:heading], content: truncated_lines.join("\n") }
      end

      # Fast token approximation: ~0.75 tokens per word (per issue spec)
      def estimate_tokens(text)
        (text.split.size / 0.75).ceil
      end

      def env_token_budget
        raw = ENV["KNOWLEDGE_CONTEXT_TOKEN_BUDGET"]
        return DEFAULT_TOKEN_BUDGET if raw.nil?

        value = raw.strip
        return DEFAULT_TOKEN_BUDGET if value.empty?

        parsed = Integer(value, exception: false)
        return DEFAULT_TOKEN_BUDGET if parsed.nil? || parsed <= 0

        parsed
      end

      def experiment_value(config_key)
        return nil unless agent_run

        experiment = ConfigurationExperiment.active_for(config_key, project: project, agent_run: agent_run)
        return nil unless experiment

        assignment = ConfigurationExperiments::Assign.call(
          configuration_experiment: experiment,
          agent_run: agent_run
        )
        normalize_experiment_value(config_key, assignment.configuration_experiment_variant.parsed_value)
      end

      def normalize_experiment_value(config_key, value)
        case config_key
        when "knowledge.token_budget"
          normalize_token_budget(value)
        when "knowledge.section_order"
          normalize_section_order(value)
        end
      end

      def normalize_token_budget(value)
        return value if value.is_a?(Integer) && value.positive?

        raise ArgumentError, "knowledge.token_budget experiment value must be a positive integer"
      end

      def normalize_section_order(value)
        unless value.is_a?(Array)
          raise ArgumentError, "knowledge.section_order experiment value must be an array"
        end

        normalized = value.map(&:to_sym)
        unless normalized.all? { |section_name| SECTION_ORDER.include?(section_name) }
          raise ArgumentError, "knowledge.section_order experiment value includes an unknown section"
        end

        normalized
      end

      def empty_result(queries_made = 0)
        { content: "", sections: [], total_tokens: 0, queries_made: queries_made }
      end
    end
  end
end
