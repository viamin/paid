# frozen_string_literal: true

module ClaudeLoginSessions
  class SubmitCode
    Result = Data.define(:success?, :error_message)

    def self.call(...)
      new(...).call
    end

    def initialize(session:, session_token:, code:)
      @session = session
      @session_token = session_token.to_s
      @code = code.to_s.strip
      @coordination = ClaudeLoginSessions::Coordination.new(session: session)
    end

    def call
      return Result.new(success?: false, error_message: "This Claude login session has expired.") if session.expired?
      return Result.new(success?: false, error_message: "The browser code is required.") if code.blank?
      return Result.new(success?: false, error_message: "The browser login session token is invalid.") unless valid_token?

      session.with_lock do
        session.reload
        return Result.new(success?: false, error_message: "This Claude login session is no longer accepting codes.") unless session.awaiting_code?

        unless coordination.live?
          session.fail!("The live Claude login process is no longer available. Start a new browser login.")
          return Result.new(success?: false, error_message: session.error_message)
        end

        session.update!(status: "authorizing", submitted_at: Time.current, error_message: nil)
        coordination.enqueue_code(code)
        Result.new(success?: true, error_message: nil)
      end
    rescue StandardError => e
      session.fail!(e.message) unless session.terminal?
      Result.new(success?: false, error_message: e.message)
    end

    private

    attr_reader :session, :session_token, :code, :coordination

    def valid_token?
      ActiveSupport::SecurityUtils.secure_compare(session.session_token, session_token)
    rescue StandardError
      false
    end
  end
end
