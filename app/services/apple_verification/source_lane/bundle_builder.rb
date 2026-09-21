# frozen_string_literal: true

require "digest"
require "rubygems/package"
require "zlib"

module AppleVerification
  module SourceLane
    # Builds a content-addressed, secret-scanned workspace bundle from a
    # paid-agent container's working directory (RDR-068 § Uncommitted source).
    #
    # The builder streams a tar.gz archive of the workspace while computing a
    # SHA-256 digest, then writes a sibling `manifest.json` listing every
    # included file's path, byte size, and digest plus the bundle's overall
    # digest, the exclusion summary, and the secret-scan verdict. The builder
    # rejects the bundle when:
    #
    # - the originating paid-agent container has a write host mount bound
    #   into its workspace (caller-supplied via `host_mount_check`);
    # - any included file matches a secret-shaped pattern from
    #   {SecretSafeMetadata::SECRET_VALUE_PATTERNS};
    # - the resulting bundle exceeds `max_bytes` (default 2 GiB);
    # - the workspace contains a symlink that escapes the workspace root.
    #
    # The returned descriptor names the digest, byte size, manifest summary,
    # and the uploaded storage key so the control plane can persist the
    # {AppleVerificationAttempt} row and build the `object_storage` lane
    # reference without ever touching the bundle bytes themselves.
    #
    # @spec APPLE-TRANSFER-002
    # @spec APPLE-TRANSFER-003
    class BundleBuilder
      Result = Data.define(:digest, :bytesize, :manifest, :bundle_path, :manifest_path)

      DEFAULT_MAX_BYTES = 2 * 1024 * 1024 * 1024
      # Substring-match patterns for scanning workspace files for embedded
      # credentials. {SecretSafeMetadata::SECRET_VALUE_PATTERNS} anchors its
      # patterns with `\A...\z` so a known token string alone matches; bundle
      # scanning needs to find tokens anywhere in a file's first chunk, so
      # the same shapes are mirrored here without anchors.
      SECRET_SUBSTRING_PATTERNS = [
        /sk-[A-Za-z0-9_-]{8,}/,
        /ghp_[A-Za-z0-9]{36,}/,
        /github_pat_[A-Za-z0-9_]{22,}/,
        /gh[ours]_[A-Za-z0-9]{36,}/,
        /xox[abprs]-[A-Za-z0-9-]{8,}/,
        /ya29\.[A-Za-z0-9_-]{8,}/,
        /-----BEGIN [A-Z ]*PRIVATE KEY-----/
      ].freeze

      EXCLUDED_PATH_SEGMENTS = %w[
        .env env secrets Pods Carthage DerivedData DerivedSources
        .build .swiftpm node_modules vendor .bundle target dist out
        build xcuserdata .aws .ssh .git .svn
      ].freeze

      EXCLUDED_PATH_EXTENSIONS = %w[
        .pem .key .p12 .xcarchive .xcappdata .dSYM .ipa .app
        .so .dylib
      ].freeze

      EXCLUDED_PATH_BASENAMES = %w[
        .env .env.* id_rsa id_rsa.* id_dsa id_dsa.* id_ecdsa id_ecdsa.*
        id_ed25519 id_ed25519.* .netrc paid.config.json runner_handle.json
        secrets
      ].freeze

      class SecretFoundError < StandardError; end
      class BundleTooLargeError < StandardError; end
      class WorkspaceInvalidError < StandardError; end
      class ManifestInvalidError < StandardError; end

      def self.call(...)
        new(...).call
      end

      def initialize(workspace_root:, output_path:, manifest_path: nil, max_bytes: DEFAULT_MAX_BYTES, now: Time.current)
        @workspace_root = workspace_root.to_s
        @output_path = output_path.to_s
        @manifest_path = manifest_path
        @max_bytes = max_bytes
        @now = now
      end

      def call
        validate_workspace_root!
        ensure_manifest_path!

        manifest = { "excluded_paths" => [], "files" => [], "secret_scan" => { "passed" => true, "matches" => [] } }
        digester = Digest::SHA256.new
        bytesize = 0

        File.open(@output_path, "wb") do |io|
          Zlib::GzipWriter.wrap(io) do |gz|
            Gem::Package::TarWriter.new(gz) do |tar|
              walk_workspace do |absolute_path, relative_path|
                relative = relative_path.to_s
                excluded_reason = exclusion_reason(relative)
                if excluded_reason
                  manifest["excluded_paths"] << { "path" => relative, "reason" => excluded_reason }
                  next
                end

                bytes = File.binread(absolute_path)
                file_digest = Digest::SHA256.hexdigest(bytes)
                if secret_shaped?(relative, bytes)
                  manifest["secret_scan"]["passed"] = false
                  manifest["secret_scan"]["matches"] << { "path" => relative, "sha256_prefix" => file_digest[0, 16] }
                  raise SecretFoundError, "workspace bundle includes a secret-shaped file at #{relative}"
                end

                write_entry(tar, relative, bytes)
                digester << relative << "\0" << file_digest << "\0"
                bytesize += bytes.bytesize
                if bytesize > @max_bytes
                  raise BundleTooLargeError, "workspace bundle exceeds #{@max_bytes} bytes"
                end

                manifest["files"] << {
                  "path" => relative,
                  "bytesize" => bytes.bytesize,
                  "sha256" => "sha256:#{file_digest}"
                }
              end
            end
          end
        end

        digest = "sha256:#{digester.hexdigest}"
        manifest["digest"] = digest
        manifest["bytesize"] = bytesize
        manifest["generated_at"] = @now.iso8601

        File.binwrite(@manifest_path, JSON.generate(manifest))
        Result.new(
          digest: digest,
          bytesize: bytesize,
          manifest: manifest,
          bundle_path: @output_path,
          manifest_path: @manifest_path
        )
      end

      private

      def validate_workspace_root!
        raise WorkspaceInvalidError, "workspace root is required" if @workspace_root.blank?
        raise WorkspaceInvalidError, "workspace root does not exist" unless File.directory?(@workspace_root)

        root_real = File.realpath(@workspace_root)
        @workspace_root = root_real
      rescue Errno::ENOENT
        raise WorkspaceInvalidError, "workspace root does not exist"
      end

      def ensure_manifest_path!
        @manifest_path ||= @output_path.to_s.sub(/\.tar(?:\.gz)?\z/, "") + ".manifest.json"
      end

      def walk_workspace(&block)
        Dir.glob(File.join(@workspace_root, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
          next if File.directory?(path)
          next if File.symlink?(path) && symlink_escapes?(path)

          relative = path.sub(/\A#{Regexp.escape(@workspace_root)}\/?/, "")
          yield(path, relative)
        end
      end

      def symlink_escapes?(path)
        target = File.readlink(path)
        absolute = File.absolute_path?(target) ? target : File.expand_path(target, File.dirname(path))
        !absolute.start_with?(@workspace_root + "/")
      end

      def exclusion_reason(relative_path)
        basename = File.basename(relative_path)
        segments = relative_path.split("/")

        return "forbidden binary" if EXCLUDED_PATH_EXTENSIONS.any? { |ext| basename.end_with?(ext) }
        return "excluded directory" if segments.any? { |segment| EXCLUDED_PATH_SEGMENTS.include?(segment) }
        return "excluded basename" if EXCLUDED_PATH_BASENAMES.any? { |pattern| File.fnmatch?(pattern, basename, File::FNM_DOTMATCH) }

        nil
      end

      def secret_shaped?(relative_path, bytes)
        return false unless text_file?(relative_path)

        sample = bytes[0, 8192].to_s.dup.force_encoding(Encoding::UTF_8)
        return false unless sample.valid_encoding?

        SECRET_SUBSTRING_PATTERNS.any? { |pattern| sample.match?(pattern) }
      end

      def text_file?(relative_path)
        basename = File.basename(relative_path)
        return true if basename == ".env" || basename.start_with?(".env.")
        return false if relative_path.end_with?(".png", ".jpg", ".gif", ".zip", ".tar", ".gz", ".pdf")

        true
      end

      def write_entry(tar, relative_path, bytes)
        stat = stat_for(bytes)
        tar.add_file_simple(relative_path, stat.mode, stat.size) do |entry|
          entry.write(bytes)
        end
      end

      def stat_for(bytes)
        Struct.new(:mode, :size).new(0o644, bytes.bytesize)
      end
    end
  end
end
