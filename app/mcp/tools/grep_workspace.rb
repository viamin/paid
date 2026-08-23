# frozen_string_literal: true

module Tools
  class GrepWorkspace < BaseTool
    include ContainerRepoSupport
    authorize :show?, ->(args) { project_for_authorization!(args.fetch(:repo_path)) }, policy_class: ProjectPolicy

    MAX_MATCHES = 200
    MAX_OUTPUT_BYTES = 100 * 1024
    MATCH_LINE_PATTERN = /\A(?<path>.*?):(?<line>\d+):(?<content>.*)\z/

    def self.tool_name = "grep_workspace"
    def self.requires_container? = true

    def self.description
      "Search a cloned workspace repo's local checkout for a string or pattern (runs against the container's files, not GitHub code search)."
    end

    def self.available_to?(user:)
      false
    end

    def self.available_for_chat?(user:, session:)
      user.present? && session&.clone_manifest_entries.present?
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          repo_path: { type: "string", description: "Workspace path of the cloned repo" },
          query: { type: "string", description: "Search query (string or basic regex pattern)" },
          path_filter: { type: "string", description: "Optional path prefix within the repo to narrow search scope (e.g. 'app/models')" }
        },
        required: %w[repo_path query]
      }
    end

    def perform(repo_path:, query:, path_filter: nil)
      raise ArgumentError, "query must be provided" if query.to_s.strip.blank?

      context = repo_context_for!(repo_path)
      normalized_repo_path = context.fetch(:repo_path)
      pathspec = validate_path_filter!(normalized_repo_path, path_filter)

      stdout, stderr, exit_code = run_grep(normalized_repo_path, query, pathspec)
      raise ArgumentError, stderr.presence || "grep_workspace failed" if exit_code > 1

      build_result(normalized_repo_path, query, stdout, exit_code)
    end

    private

    def validate_path_filter!(repo_path, path_filter)
      return nil if path_filter.to_s.strip.blank?

      _, relative_path = normalize_repo_relative_path(repo_path, path_filter)
      relative_path
    end

    def run_grep(repo_path, query, pathspec)
      env = [ encode_env("GREP_WORKSPACE_QUERY_B64", query) ]
      pathspec_clause = pathspec.present? ? " -- #{Shellwords.escape(pathspec)}" : ""
      script = %(QUERY=$(printf %s "$GREP_WORKSPACE_QUERY_B64" | base64 -d) && ) +
        %(git -C #{Shellwords.escape(repo_path)} grep -n --no-color -I --untracked -e "$QUERY"#{pathspec_clause})
      git_exec!(script, env:)
    end

    def build_result(repo_path, query, stdout, exit_code)
      return { repo_path:, query:, matches: [], total_matches: 0, truncated: false } if exit_code == 1

      truncated_output, output_truncated = truncate_output(stdout)
      matches = parse_matches(truncated_output, output_truncated)
      matches_truncated = matches.length > MAX_MATCHES

      {
        repo_path: repo_path,
        query: query,
        matches: matches.first(MAX_MATCHES),
        total_matches: [ matches.length, MAX_MATCHES ].min,
        truncated: output_truncated || matches_truncated
      }
    end

    def parse_matches(text, output_truncated)
      lines = text.split("\n")
      lines.pop if output_truncated && !text.end_with?("\n")

      lines.filter_map { |line| parse_match_line(line) }
    end

    def parse_match_line(line)
      match = MATCH_LINE_PATTERN.match(line)
      return nil unless match

      { path: match[:path], line: match[:line].to_i, content: match[:content] }
    end

    def truncate_output(output)
      text = output.to_s
      return [ text, false ] if text.bytesize <= MAX_OUTPUT_BYTES

      [ text.byteslice(0, MAX_OUTPUT_BYTES).scrub(""), true ]
    end
  end
end
