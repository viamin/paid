# frozen_string_literal: true

module Knowledge
  # Canonical Paid KB URIs — stable handles for knowledge artifacts and chunks
  # that can be cited in search results, browse views, context-bundle
  # citations, and audit metadata instead of raw database ids.
  #
  # Grammar:
  #   paidkb://project/<project_id>/artifact/<artifact_type>/<scope>/<identifier>
  #   paidkb://project/<project_id>/chunk/<chunk_uuid>
  #   paidkb://project/<project_id>/commit/<sha>/artifact/<artifact_type>/<scope>/<identifier>
  #
  # Normalization:
  # - <scope> and <identifier> are percent-encoded (RFC 3986) so a stray "/"
  #   or space in a scope_path/identifier can't be mistaken for a path
  #   separator.
  # - A blank scope_path or identifier encodes as an empty path segment
  #   (producing a literal "//" or trailing "/") rather than a sentinel
  #   string. Decode preserves "" so a stored empty-string artifact still
  #   resolves back to its row; nil is normalized to "" on round-trip
  #   because the grammar has no way to distinguish the two.
  # - The active-view handle (no "commit" segment) always resolves to
  #   whatever artifact/chunk is currently active; the "commit" segment adds
  #   a version-pinned handle without changing the active-view grammar.
  #
  # @spec KNOWLEDGE-URI-001
  class Uri
    class InvalidUriError < ArgumentError; end

    SCHEME = "paidkb"

    Artifact = Data.define(:project_id, :artifact_type, :scope_path, :identifier, :commit_sha) do
      def kind
        :artifact
      end
    end

    Chunk = Data.define(:project_id, :chunk_id) do
      def kind
        :chunk
      end
    end

    class << self
      def for_artifact(artifact, commit_sha: nil)
        build_artifact(
          project_id: artifact.project_id,
          artifact_type: artifact.artifact_type,
          scope_path: artifact.scope_path,
          identifier: artifact.identifier,
          commit_sha: commit_sha
        )
      end

      def for_chunk(chunk)
        build_chunk(project_id: chunk.project_id, chunk_id: chunk.id)
      end

      def build_artifact(project_id:, artifact_type:, scope_path:, identifier:, commit_sha: nil)
        segments = [ "project", project_id ]
        segments += [ "commit", commit_sha ] if commit_sha.present?
        segments += [ "artifact", artifact_type, encode(scope_path), encode(identifier) ]
        "#{SCHEME}://#{segments.join('/')}"
      end

      def build_chunk(project_id:, chunk_id:)
        "#{SCHEME}://project/#{project_id}/chunk/#{chunk_id}"
      end

      def parse(uri_string)
        scheme, separator, rest = uri_string.to_s.partition("://")
        raise InvalidUriError, "unsupported knowledge URI: #{uri_string.inspect}" unless separator.present? && scheme == SCHEME

        segments = rest.split("/", -1)
        raise InvalidUriError, "malformed knowledge URI: #{uri_string.inspect}" unless segments.shift == "project"

        project_id = segments.shift
        raise InvalidUriError, "missing project id: #{uri_string.inspect}" if project_id.blank?

        parse_segments(project_id, segments, uri_string)
      end

      private

      def parse_segments(project_id, segments, uri_string)
        case segments.shift
        when "chunk"
          parse_chunk(project_id, segments, uri_string)
        when "commit"
          parse_commit(project_id, segments, uri_string)
        when "artifact"
          parse_artifact(project_id, nil, segments, uri_string)
        else
          raise InvalidUriError, "malformed knowledge URI: #{uri_string.inspect}"
        end
      end

      def parse_chunk(project_id, segments, uri_string)
        chunk_id = segments.shift
        raise InvalidUriError, "malformed knowledge URI: #{uri_string.inspect}" if chunk_id.blank? || segments.any?

        Chunk.new(project_id: project_id, chunk_id: chunk_id)
      end

      def parse_commit(project_id, segments, uri_string)
        commit_sha = segments.shift
        raise InvalidUriError, "missing commit sha: #{uri_string.inspect}" if commit_sha.blank?
        raise InvalidUriError, "malformed knowledge URI: #{uri_string.inspect}" unless segments.shift == "artifact"

        parse_artifact(project_id, commit_sha, segments, uri_string)
      end

      def parse_artifact(project_id, commit_sha, segments, uri_string)
        raise InvalidUriError, "malformed knowledge URI: #{uri_string.inspect}" unless segments.size == 3

        artifact_type, scope_segment, identifier_segment = segments
        raise InvalidUriError, "missing artifact type: #{uri_string.inspect}" if artifact_type.blank?

        Artifact.new(
          project_id: project_id,
          artifact_type: artifact_type,
          scope_path: decode(scope_segment),
          identifier: decode(identifier_segment),
          commit_sha: commit_sha
        )
      end

      def encode(value)
        value.present? ? ERB::Util.url_encode(value.to_s) : ""
      end

      def decode(segment)
        segment.nil? ? nil : CGI.unescape(segment)
      end
    end
  end
end
