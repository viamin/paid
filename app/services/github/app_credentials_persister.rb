# frozen_string_literal: true

require "yaml"

module Github
  # Persists the result of a GitHub App manifest exchange into the running
  # application's encrypted Rails credentials so every worker (and the next
  # process restart) can see the same values.
  #
  # Writing to ENV from the controller is misleading: ENV is process-local, so
  # any worker that didn't handle the callback still has an unset
  # `PAID_AGENT_APP_*`, and the values evaporate on restart/redeploy. Writing
  # to Rails credentials is durable across workers and restarts as long as the
  # encrypted file is on a shared, writable volume and `RAILS_MASTER_KEY` (or
  # `config/master.key`) is available.
  #
  # When persistence is not possible — for example in production where the
  # credentials file is read-only and the master key is supplied via
  # `RAILS_MASTER_KEY` but never written back — the persister returns a
  # `:manual` outcome with the exact snippet the operator must add to their
  # credentials file or process manager. The caller surfaces those
  # instructions to the operator; nothing is silently lost.
  class AppCredentialsPersister
    Result = Struct.new(:status, :credentials_path, :written_keys, :manual_instructions, keyword_init: true) do
      def persisted? = status == :persisted
      def manual? = status == :manual
    end

    class << self
      def call(result:)
        new(result: result).call
      end
    end

    def initialize(result:)
      @result = result
    end

    def call
      payload = build_payload

      if writable_credentials?
        write_to_credentials(payload)
        Result.new(
          status: :persisted,
          credentials_path: credentials.content_path.to_s,
          written_keys: payload.keys.map(&:to_s).sort
        )
      else
        Result.new(
          status: :manual,
          credentials_path: credentials.content_path.to_s,
          written_keys: [],
          manual_instructions: manual_instructions(payload)
        )
      end
    rescue ActiveSupport::EncryptedFile::MissingKeyError,
      ActiveSupport::MessageEncryptor::InvalidMessage,
      Errno::EACCES,
      Errno::EROFS,
      Errno::ENOSPC
      Result.new(
        status: :manual,
        credentials_path: credentials.content_path.to_s,
        written_keys: [],
        manual_instructions: manual_instructions(payload)
      )
    end

    private

    attr_reader :result

    def build_payload
      {
        paid_agent_app_id: result.app_id.to_s,
        paid_agent_app_slug: result.slug,
        paid_agent_app_private_key: result.private_key.to_s,
        paid_agent_app_webhook_secret: result.webhook_secret
      }.compact_blank.transform_keys(&:to_sym)
    end

    def writable_credentials?
      credentials.key? && credentials_writable?
    end

    def credentials_writable?
      path = credentials.content_path
      return false unless path

      parent = path.dirname
      File.writable?(parent.to_s) && (path.exist? ? File.writable?(path.to_s) : true)
    end

    def credentials
      Rails.application.credentials
    end

    def write_to_credentials(payload)
      existing = credentials.config || {}
      merged = deep_merge(existing, payload.transform_keys(&:to_s))
      yaml = YAML.dump(stringify_keys(merged))
      credentials.write(yaml)
    end

    def deep_merge(left, right)
      left.deep_merge(right)
    end

    def stringify_keys(hash)
      hash.each_with_object({}) do |(key, value), acc|
        acc[key.to_s] = value.is_a?(Hash) ? stringify_keys(value) : value
      end
    end

    def manual_instructions(payload)
      yaml_snippet = payload.map { |key, value| "  #{key}: #{value.inspect}" }.join("\n")
      intro = <<~INTRO.squish
        Add the following values to your Rails credentials
        (#{credentials.content_path}) using `bin/rails credentials:edit`,
        or expose them as environment variables
        (PAID_AGENT_APP_ID, PAID_AGENT_APP_SLUG, PAID_AGENT_APP_PRIVATE_KEY,
        PAID_AGENT_APP_WEBHOOK_SECRET) via your process manager:
      INTRO
      # Preserve the YAML line breaks in the snippet — squishing the joined
      # output would collapse the PEM and other multi-line values into a single
      # paragraph and make the snippet non-copyable into credentials. The
      # squish above only flattens whitespace within the intro paragraph.
      "#{intro}\n#{yaml_snippet}\n"
    end
  end
end
