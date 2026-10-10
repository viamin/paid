# frozen_string_literal: true

module Api
  module V1
    class InboxController < BaseController
      DEFAULT_LIMIT = 50
      MAX_LIMIT = 100

      before_action -> { require_scope!(:inbox) }, only: %i[index count show]
      before_action -> { require_scope!(:chat) }, only: :chat

      # @spec MOBILE-API-006 MOBILE-API-010
      def index
        filters = inbox_filters
        return if conditional_response?(filters)

        entries = Inbox::Queue.call(user: current_user, **filters.slice(:project, :kind, :sort))
        page = paginated_entries(entries)
        listed_entries = page.first(inbox_limit)
        payload = { entries: listed_entries.map { |entry| InboxEntrySerializer.render_list(entry) } }
        payload[:next_cursor] = listed_entries.last.id if page.size > inbox_limit

        render json: payload
      end

      # @spec MOBILE-API-007 MOBILE-API-010
      def count
        return if conditional_response?({})

        render json: { count: Inbox::Count.call(user: current_user) }
      end

      # @spec MOBILE-API-008
      def show
        entry = Inbox::FindEntry.call(user: current_user, entry_id: params[:entry_id])
        return render_entry_not_found unless entry

        render json: { entry: InboxEntrySerializer.render(entry) }
      end

      # @spec MOBILE-API-009
      def chat
        entry = Inbox::FindEntry.call(user: current_user, entry_id: params[:entry_id])
        return render_entry_not_found unless entry

        chat_session = Inbox::OpenInteractiveChat.call(user: current_user, entry:)
        render json: { chat_session_id: chat_session.id }, status: :created
      end

      private

      def inbox_filters
        {
          project: scoped_project,
          kind: valid_kind,
          sort: valid_sort,
          limit: inbox_limit,
          cursor: params[:cursor].presence
        }.compact
      end

      def scoped_project
        return if params[:project_id].blank?

        project = policy_scope(Project).find(params[:project_id])
        authorize project, :show?
        project
      end

      def valid_kind
        kind = params[:kind].to_s
        Inbox::Queue::KINDS.include?(kind) ? kind : nil
      end

      def valid_sort
        Inbox::Queue::SORTS.key?(params[:sort].to_s) ? params[:sort].to_s : Inbox::Queue::DEFAULT_SORT
      end

      def conditional_response?(filters)
        etag = inbox_etag(filters)
        response.headers["ETag"] = etag
        response.headers["Cache-Control"] = "private, max-age=0"
        return false unless request.headers["If-None-Match"] == etag

        head :not_modified
        true
      end

      def inbox_etag(filters)
        payload = [ current_user.id, filters.slice(:kind, :sort, :limit, :cursor).merge(project_id: filters[:project]&.id), inbox_version ]
        %Q("#{Digest::SHA256.hexdigest(payload.to_json)}")
      end

      def paginated_entries(entries)
        entries_after_cursor(entries).first(inbox_limit + 1)
      end

      def entries_after_cursor(entries)
        return entries if params[:cursor].blank?

        cursor_index = entries.index { |entry| entry.id == params[:cursor] }
        return [] unless cursor_index

        entries.drop(cursor_index + 1)
      end

      def inbox_limit
        return DEFAULT_LIMIT if params[:limit].blank?

        params[:limit].to_i.clamp(1, MAX_LIMIT)
      end

      def inbox_version
        Dashboard::CacheVersion.current(current_user.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)
      end

      def render_entry_not_found
        render_error("not_found", "Entry is not in the inbox.", :not_found)
      end
    end
  end
end
