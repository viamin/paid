# frozen_string_literal: true

require "yaml"
require "open3"
require "pathname"

module IntentConformance
  # Read-only view of the frozen corpus manifest backing a shadow
  # evaluation. Resolves the manifest from an absolute path or from the
  # repository root (Rails.root) so the UI and services never receive raw
  # hashes with unknown shape, and re-validates the content digest so a
  # changed corpus cannot silently feed an existing evaluation.
  # @spec INTENT-CONFORMANCE-ROLLOUT-005
  class ShadowEvaluationCorpus
    MissingManifest = Class.new(StandardError)
    ChangedManifest = Class.new(StandardError)
    UncommittedManifest = Class.new(StandardError)

    attr_reader :path, :commit, :digest

    def initialize(path:, commit: "", digest: "")
      @path = path.to_s
      @commit = commit.to_s
      @digest = digest.to_s
    end

    def cases
      @cases ||= begin
        document = YAML.safe_load_file(resolved_path, aliases: true)
        raise MissingManifest, "corpus manifest is not a mapping with a cases list" unless document.is_a?(Hash) && document["cases"].is_a?(Array)

        document.fetch("cases")
      end
    end

    def case_ids
      cases.map { |corpus_case| corpus_case["id"] }
    end

    def find_case(case_id)
      cases.find { |corpus_case| corpus_case["id"] == case_id }
    end

    # Manifest-level reviewer/rubric identity for provenance (model, prompt
    # version, prompt digest). Falls back to empty strings for manifests
    # without a reviewer block.
    def reviewer_identity
      document = YAML.safe_load_file(resolved_path, aliases: true) || {}
      reviewer = document.is_a?(Hash) ? document["reviewer"] : nil
      {
        "model" => reviewer.is_a?(Hash) ? reviewer["model"].to_s : "",
        "prompt_version" => reviewer.is_a?(Hash) ? reviewer["prompt_version"].to_s : "",
        "prompt_sha256" => reviewer.is_a?(Hash) ? reviewer["prompt_sha256"].to_s : ""
      }
    end

    def content_digest
      require "digest"
      Digest::SHA256.file(resolved_path).hexdigest
    end

    # Binds the local manifest used for labeling to a committed Git blob. The
    # report can consequently name a revision whose exact corpus bytes can be
    # recovered, rather than merely recording an operator-supplied SHA.
    def verify_commit!
      resolved_commit = resolve_commit
      committed_digest = Digest::SHA256.hexdigest(git_show(resolved_commit))
      raise UncommittedManifest, "corpus manifest does not match #{resolved_commit}" unless committed_digest == content_digest

      resolved_commit
    end

    # A changed corpus is a new evidence generation: the caller must start a
    # new evaluation rather than label against a moving target.
    def matches_recorded_digest?
      return true if digest.blank?

      content_digest == digest
    end

    def resolved_path
      @resolved_path ||= begin
        candidate = File.expand_path(path, Rails.root)
        candidate = File.expand_path(path) unless File.exist?(candidate)
        raise MissingManifest, "corpus manifest #{path.inspect} was not found" unless File.exist?(candidate)

        candidate
      end
    end

    private

    def resolve_commit
      reference = commit.presence || "HEAD"
      raise UncommittedManifest, "manifest commit must be a Git SHA" unless reference == "HEAD" || reference.match?(/\A[0-9a-f]{7,64}\z/i)

      stdout, _stderr, status = Open3.capture3("git", "-C", Rails.root.to_s, "rev-parse", "--verify", "#{reference}^{commit}")
      raise UncommittedManifest, "manifest commit #{reference.inspect} does not exist" unless status.success?

      stdout.strip
    end

    def git_show(resolved_commit)
      stdout, _stderr, status = Open3.capture3("git", "-C", Rails.root.to_s, "show", "#{resolved_commit}:#{repository_relative_path}")
      raise UncommittedManifest, "corpus manifest #{path.inspect} is absent from commit #{resolved_commit}" unless status.success?

      stdout
    end

    def repository_relative_path
      relative_path = Pathname.new(File.realpath(resolved_path)).relative_path_from(Pathname.new(File.realpath(Rails.root))).to_s
      raise UncommittedManifest, "corpus manifest #{path.inspect} must be inside the repository" if relative_path == ".." || relative_path.start_with?("../")

      relative_path
    end
  end
end
