# frozen_string_literal: true

module ConflictRepairs
  # Builds the bounded, complete evidence sections for a conflict scope
  # assessment. The result-path inventory is complete — every changed path is
  # listed — Git blob SHAs mechanically verify byte-identical base imports so
  # they need no diff text, and every unverified path keeps bounded diff
  # evidence. When the complete evidence cannot be held within bounds, or path
  # metadata could forge inventory lines, coverage fails closed with an
  # explicit reason instead of silently omitting paths the response must
  # classify (#5312). Semantic scope judgments stay with agent_harness.
  # @spec AUTO-MERGE-011
  class ScopeEvidence
    MAX_INVENTORY_CHARS = 30_000
    MAX_EVIDENCE_CHARS = 30_000
    MAX_PATCH_CHARS = 4_000
    MIN_PATCH_CHARS = 200
    UNTRUSTWORTHY_PATH_PATTERN = /[\u0000-\u001F\u007F]/
    NO_PATCH_NOTE = "no textual patch available (binary file or omitted by the compare API)"
    VERIFIED_MARKER = "verified-base-import"
    MODIFIED_MARKER = "base-import-modified"
    AUTHORED_MARKER = "authored-candidate"

    def initialize(base_comparison:, result_comparison:)
      @base_comparison = base_comparison
      @result_comparison = result_comparison
    end

    def result_paths
      @result_paths ||= paths_for(result_files)
    end

    def base_import_paths
      @base_import_paths ||= paths_for(base_files)
    end

    def verified_base_import_paths
      @verified_base_import_paths ||= result_paths.select do |path|
        base_blobs[path].present? && base_blobs[path] == result_blobs[path]
      end
    end

    def prompt_variables
      {
        result_count: result_paths.size,
        result_inventory: result_inventory_section,
        candidate_count: candidate_paths.size,
        candidate_evidence: candidate_evidence_section
      }
    end

    def coverage_failure
      untrustworthy_path_failure || inventory_overflow_failure || evidence_overflow_failure
    end

    private

    attr_reader :base_comparison, :result_comparison

    def candidate_paths
      @candidate_paths ||= result_paths - verified_base_import_paths
    end

    def base_only_paths
      base_import_paths - result_paths
    end

    def result_inventory_section
      lines = result_paths.map { |path| "- #{path} [#{marker_for(path)}]" }
      if base_only_paths.any?
        lines << "(#{base_only_paths.size} additional base-import #{'path'.pluralize(base_only_paths.size)} changed only in the base-import range and need no classification)"
      end
      lines.join("\n").presence || "(no changed paths in the pre-run-to-result range)"
    end

    def marker_for(path)
      if verified_base_import_paths.include?(path)
        VERIFIED_MARKER
      elsif base_import_paths.include?(path)
        MODIFIED_MARKER
      else
        AUTHORED_MARKER
      end
    end

    def candidate_evidence_section
      return "None: every result path is a mechanically verified base import." if candidate_paths.empty?

      candidate_evidence_for(candidate_patch_share)
    end

    def candidate_evidence_for(patch_share)
      candidate_paths.map { |path| candidate_entry(path, patch_share) }.join("\n\n")
    end

    def candidate_entry(path, patch_share)
      file = result_files_by_path[path]
      result_segment, used = patch_segment("result-range patch", file, patch_share)
      base_file = base_files_by_path[path]
      base_segment, = base_file ?
        patch_segment("base-import patch", base_file, patch_share - used) :
        [ "base-import patch: path not present in the base-import comparison", 0 ]
      <<~ENTRY
        #{path} [#{marker_for(path)}]
        status: #{status_line(file)}#{rename_note(file)}
        #{result_segment}
        #{base_segment}
      ENTRY
    end

    def patch_segment(label, file, budget)
      patch = file_value(file, :patch).to_s
      return [ "#{label}: #{NO_PATCH_NOTE}", 0 ] if patch.blank?
      return [ "#{label}: omitted from this bounded entry (entry budget exhausted)", 0 ] if budget.to_i <= 0

      excerpt = patch[0, budget]
      if excerpt.length < patch.length
        [ "#{label} (excerpt: first #{excerpt.length} of #{patch.length} characters):\n#{excerpt}\n[excerpt ends]", excerpt.length ]
      else
        [ "#{label}:\n#{patch}", patch.length ]
      end
    end

    def candidate_patch_share
      return @candidate_patch_share if defined?(@candidate_patch_share)

      @candidate_patch_share = if evidence_fits?(MAX_PATCH_CHARS)
        MAX_PATCH_CHARS
      elsif patch_evidence_required? && evidence_fits?(MIN_PATCH_CHARS)
        first_unfitting_patch_share - 1
      elsif !patch_evidence_required? && evidence_fits?(0)
        0
      end
    end

    def evidence_fits?(patch_share)
      candidate_evidence_for(patch_share).length <= MAX_EVIDENCE_CHARS
    end

    def first_unfitting_patch_share
      (MIN_PATCH_CHARS..MAX_PATCH_CHARS).bsearch do |patch_share|
        !evidence_fits?(patch_share)
      end
    end

    def patch_evidence_required?
      candidate_paths.any? do |path|
        files_for_path(path).any? { |file| file_value(file, :patch).present? }
      end
    end

    def files_for_path(path)
      [ result_files_by_path[path], base_files_by_path[path] ].compact
    end

    def untrustworthy_path_failure
      offenders = untrustworthy_path_values.size
      return unless offenders.positive?

      "Scope assessment input evidence was incomplete: #{offenders} path #{'value'.pluralize(offenders)} " \
        "contained control characters or line breaks that could forge inventory lines"
    end

    def inventory_overflow_failure
      return unless result_inventory_section.length > MAX_INVENTORY_CHARS

      "Scope assessment input evidence was incomplete: the complete result-path inventory " \
        "(#{result_paths.size} #{'path'.pluralize(result_paths.size)}) exceeded the bounded " \
        "inventory budget of #{MAX_INVENTORY_CHARS} characters"
    end

    def evidence_overflow_failure
      return unless candidate_paths.any?
      return if candidate_patch_share

      "Scope assessment input evidence was incomplete: #{candidate_paths.size} unverified " \
        "#{'path'.pluralize(candidate_paths.size)} exceeded the bounded diff-evidence budget of " \
        "#{MAX_EVIDENCE_CHARS} characters; refusing to omit path evidence the response must classify"
    end

    def untrustworthy_path_values
      (result_paths + base_import_paths + previous_filenames)
        .select { |value| value.match?(UNTRUSTWORTHY_PATH_PATTERN) }
    end

    def previous_filenames
      (base_files + result_files).filter_map { |file| file_value(file, :previous_filename).presence }
    end

    def result_files
      @result_files ||= files_for(result_comparison)
    end

    def base_files
      @base_files ||= files_for(base_comparison)
    end

    def files_for(comparison)
      Array(comparison[:files] || comparison["files"])
    end

    def result_files_by_path
      @result_files_by_path ||= files_by_path(result_files)
    end

    def base_files_by_path
      @base_files_by_path ||= files_by_path(base_files)
    end

    def files_by_path(files)
      files.filter_map { |file| path_of(file) ? [ path_of(file), file ] : nil }.to_h
    end

    def path_of(file)
      (file[:filename] || file["filename"]).to_s.presence
    end

    def paths_for(files)
      files.filter_map { |file| path_of(file) }.uniq.sort
    end

    def file_value(file, key)
      file[key] || file[key.to_s]
    end

    def base_blobs
      @base_blobs ||= files_by_path(base_files).transform_values { |file| file_value(file, :sha).to_s }
    end

    def result_blobs
      @result_blobs ||= files_by_path(result_files).transform_values { |file| file_value(file, :sha).to_s }
    end

    def status_line(file)
      "#{file_value(file, :status).presence || 'unknown'}, " \
        "+#{file_value(file, :additions).to_i}/-#{file_value(file, :deletions).to_i}"
    end

    def rename_note(file)
      previous = file_value(file, :previous_filename).presence
      previous ? "; renamed from #{previous}" : ""
    end
  end
end
