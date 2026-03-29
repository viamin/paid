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
      SECTION_ORDER = %i[routes symbols hotspots decisions stats].freeze

      attr_reader :issue, :project, :token_budget

      # issue is accepted for future relevance-ranking of artifacts.
      # Currently unused — all active artifacts are included project-wide.
      def initialize(issue:, project:, token_budget: nil)
        @issue = issue
        @project = project
        @token_budget = token_budget || env_token_budget
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

        SECTION_ORDER.each do |section_name|
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

        # Sort by hotspot rank (lower = hotter), then by revision count descending for ties.
        # ChurnHotspotCollector stores rank and revisions in metadata.
        sorted = artifacts.sort_by do |a|
          metadata = a.metadata || {}
          rank = metadata["rank"]
          revisions = metadata["revisions"] || metadata["revision_count"]
          [ rank.nil? ? 1 : 0, rank.to_i, -revisions.to_i ]
        end

        lines = sorted.first(10).map do |a|
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
        records = DecisionRecord.for_project(project).where(status: %w[active draft]).order(created_at: :desc).limit(10)
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
        KnowledgeArtifact
          .for_project(project)
          .active
          .by_type(type)
          .order(:identifier)
          .limit(20)
          .to_a
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

      def empty_result(queries_made = 0)
        { content: "", sections: [], total_tokens: 0, queries_made: queries_made }
      end
    end
  end
end
