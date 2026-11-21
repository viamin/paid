# frozen_string_literal: true

module ChatSessions
  # Reads one contiguous tool run without materializing its omitted history.
  # @spec CHAT-API-024 CHAT-API-027
  class LoadToolHistory
    Page = Data.define(:messages, :has_more, :anchor_id)

    def self.leading(scope:, messages:)
      return unless messages.first&.groupable_tool?

      run = run_scope(scope, anchor_id: messages.first.id)
      first_id = run.where(id: ...messages.first.id).minimum(:id)
      return unless first_id

      { first_id:, before_id: messages.first.id,
        anchor_id: messages.take_while(&:groupable_tool?).last.id,
        chat_session_id: messages.first.chat_session_id }
    end

    def self.call(chat_session:, anchor_id:, before_id:, limit:)
      scope = chat_session.messages
      anchor = scope.groupable_tools.where(id: anchor_id).pick(:id)
      raise ActiveRecord::RecordNotFound, "Tool history anchor not found" unless anchor

      scope = run_scope(scope, anchor_id: anchor).where(id: ...before_id)
      messages = scope.includes(chat_diagram: { comments: :actor })
        .reorder(created_at: :desc, id: :desc).limit(limit).reverse
      has_more = messages.any? && scope.where(id: ...messages.first.id).exists?
      Page.new(messages:, has_more:, anchor_id: anchor)
    end

    def self.run_scope(scope, anchor_id:)
      base = scope.except(:includes, :preload, :eager_load).reorder(nil)
      boundary = base.where(id: ...anchor_id)
        .where.not(ChatMessage.groupable_tools.where_clause.ast).maximum(:id)
      run = base.groupable_tools.where(id: ..anchor_id)
      boundary ? run.where("chat_messages.id > ?", boundary) : run
    end
    private_class_method :run_scope
  end
end
