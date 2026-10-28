# frozen_string_literal: true

module Api
  module V1
    class InboxController < BaseController
      DEFAULT_LIMIT = 50
      MAX_LIMIT = 100

      before_action -> { require_scope!(:inbox) }, only: %i[index count show remove_entry restore_entry recover_manual_review]
      before_action -> { require_scope!(:chat) }, only: :chat

      # @spec MOBILE-API-006 MOBILE-API-010
      def index
        authorize :inbox, policy_class: InboxPolicy
        policy_scope(:inbox, policy_scope_class: InboxPolicy::Scope)

        filters = inbox_filters
        return if conditional_response?(filters)

        entries = Inbox::Queue.call(user: current_user, **filters.slice(:project, :kind, :sort, :scope))
        page = paginated_entries(entries)
        listed_entries = page.first(inbox_limit)
        payload = { entries: listed_entries.map { |entry| InboxEntrySerializer.render_list(entry) } }
        payload[:next_cursor] = listed_entries.last.id if page.size > inbox_limit

        render json: payload
      end

      # @spec MOBILE-API-007 MOBILE-API-010
      def count
        authorize :inbox, policy_class: InboxPolicy
        count = Inbox::Count.call(user: current_user)
        return if conditional_response?({})

        render json: { count: }
      end

      # @spec MOBILE-API-008
      def show
        authorize :inbox, policy_class: InboxPolicy
        entry = Inbox::FindEntry.call(user: current_user, entry_id: params[:entry_id])
        return render_entry_not_found unless entry

        render json: { entry: InboxEntrySerializer.render(entry) }
      end

      # @spec MOBILE-API-009 QUESTION-EXPLORATION-012
      # A clarifying-questions entry opens the same linked conversation the
      # Inbox detail pane's "Answer in chat" affordance opens, under the same
      # manage-issues gate, so HTML and API opens carry matching subject/actor
      # context. Every other entry keeps its personal interactive chat.
      def chat
        authorize :inbox, policy_class: InboxPolicy
        entry = Inbox::FindEntry.call(user: current_user, entry_id: params[:entry_id])
        return render_entry_not_found unless entry

        chat_session = if entry.clarifying_questions? && entry.issue
          authorize entry.project, :manage_issues?, policy_class: ProjectPolicy
          ClarifyingQuestions::OpenChat.call(issue: entry.issue, user: current_user)
        else
          Inbox::OpenInteractiveChat.call(user: current_user, entry_id: params[:entry_id])
        end
        render json: { chat_session_id: chat_session.id }, status: :created
      rescue GithubClient::Error => e
        render_error(:bad_gateway, :github_error, "Failed to load clarifying questions: #{e.message}")
      end

      # API counterpart to the HTML action; both delegate authorization-safe
      # mutation and active-work reconciliation to the same service.
      # @spec OPERATOR-INBOX-002L @spec ISSUE-REOPEN-REVIEW-005
      def recover_manual_review
        authorize :inbox, :show?, policy_class: InboxPolicy
        entry = entry_for_mutation
        return render_entry_not_found unless entry&.manual_review?

        authorize entry.project, :run_agent?, policy_class: ProjectPolicy
        result = Issues::RecoverManualReview.call(issue: entry.issue, actor: current_user,
          decision: params[:decision], reason: params[:reason])
        if result.success?
          render json: { recovered: true, action: result.message, agent_run_id: result.agent_run&.id }
        else
          render_error(:unprocessable_entity, result.code, result.message)
        end
      end

      # RDR-077: removal hides the request for this user only; the request,
      # its questions, and its authorization are untouched.
      # @spec INBOX-PHASE-RELEVANCE-006
      def remove_entry
        authorize :inbox, policy_class: InboxPolicy
        entry = entry_for_mutation
        return render_entry_not_found unless entry

        Inbox::Removals::Remove.call(entry:, user: current_user)
        render json: { removed: true, entry_id: entry.id }
      end

      # @spec INBOX-PHASE-RELEVANCE-006
      def restore_entry
        authorize :inbox, policy_class: InboxPolicy
        entry = entry_for_mutation
        return render_entry_not_found unless entry

        Inbox::Removals::Restore.call(entry:, user: current_user)
        render json: { restored: true, entry_id: entry.id }
      end

      private

      def entry_for_mutation
        Inbox::FindEntry.call(user: current_user, entry_id: params[:entry_id])
      end

      def inbox_filters
        {
          project: scoped_project,
          kind: valid_kind,
          sort: valid_sort,
          scope: valid_scope,
          limit: inbox_limit,
          cursor: params[:cursor].presence
        }.compact
      end

      # @spec INBOX-PHASE-RELEVANCE-002
      def valid_scope
        scope = params[:scope].to_s
        return nil if scope.blank?

        Inbox::Queue::SCOPES.include?(scope) ? scope : Inbox::Queue::ACTIONABLE_SCOPE
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
        payload = [ current_user.id, filters.slice(:kind, :sort, :scope, :limit, :cursor).merge(project_id: filters[:project]&.id), inbox_version ]
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
        render_error(:not_found, :not_found, "Entry is not in the inbox.")
      end
    end
  end
end
