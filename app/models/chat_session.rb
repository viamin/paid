# frozen_string_literal: true

class ChatSession < ApplicationRecord
  include TenantScoped
  STATUSES = %w[active idle closed archived].freeze
  MODES = %w[api workspace].freeze
  IDLE_TIMEOUT_DURATION = 30.minutes

  before_validation :set_external_id, on: :create
  before_create :generate_proxy_token
  after_create_commit :broadcast_sidebar_prepend
  after_update_commit :broadcast_sidebar_refresh
  after_destroy_commit :broadcast_sidebar_remove

  belongs_to :project, optional: true
  belongs_to :runner, -> { with_discarded }, optional: true
  belongs_to :provider, -> { with_discarded }, class_name: "Provider", foreign_key: :runner_id, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  has_many :messages, class_name: "ChatMessage", dependent: :destroy
  has_many :token_usages, dependent: :destroy
  has_many :change_intents, dependent: :nullify
  has_many :chat_session_projects, dependent: :destroy
  has_many :projects, through: :chat_session_projects
  has_many :change_intents, dependent: :nullify

  validates :status, inclusion: { in: STATUSES }
  validates :mode, inclusion: { in: MODES }
  validates :external_id, uniqueness: true
  validate :runner_must_belong_to_same_account
  validate :project_must_belong_to_same_account

  def provider_id
    runner_id
  end

  def provider_id=(value)
    self.runner_id = value
  end

  def provider=(value)
    return self.runner = value if value.is_a?(Runner) || value.nil?

    super
  end

  scope :active, -> { where(status: "active") }
  scope :visible, -> { where.not(status: "archived") }
  scope :archived_only, -> { where(status: "archived") }
  scope :idle_expired, -> { where(status: "active").where("idle_timeout_at < ?", Time.current) }
  scope :with_preview_content, lambda {
    preview_subquery = ChatMessage.where("chat_messages.chat_session_id = chat_sessions.id")
      .where.not(role: "system")
      .where.not(content: [ nil, "" ])
      .order(:created_at)
      .limit(1)
      .select(:content)
      .to_sql

    select("chat_sessions.*", "(#{preview_subquery}) AS preview_content")
  }

  def active?
    status == "active"
  end

  def archived?
    status == "archived"
  end

  def sidebar_list_target(status: self.status)
    status == "archived" ? "chat_sessions_list_archived" : "chat_sessions_list_active"
  end

  def sidebar_empty_state_target(status: self.status)
    "#{sidebar_list_target(status: status)}_empty_state"
  end

  def generate_title_from_content!
    return if title.present?

    first_user_message = messages.where(role: "user").order(:created_at).first
    return unless first_user_message&.content.present?

    generated = first_user_message.content.to_s.tr("\n", " ").truncate(80)
    update_columns(title: generated)
  end

  def ensure_proxy_token!
    return proxy_token if proxy_token.present?

    token = SecureRandom.hex(32)
    updated_rows = self.class.where(id: id, proxy_token: nil).update_all(proxy_token: token)

    if updated_rows == 1
      self.proxy_token = token
    else
      reload
    end

    proxy_token
  end

  def total_tokens_input
    token_usages.sum(:input_tokens)
  end

  def total_tokens_output
    token_usages.sum(:output_tokens)
  end

  def total_tokens
    token_usages.sum(Arel.sql("input_tokens + output_tokens"))
  end

  def estimated_cost_cents
    token_usages.sum(:cost_cents)
  end

  def page_context
    return {} unless metadata.is_a?(Hash)

    context = metadata["page_context"]
    context.is_a?(Hash) ? context : {}
  end

  private

  def set_external_id
    self.external_id ||= SecureRandom.uuid
  end

  def generate_proxy_token
    self.proxy_token ||= SecureRandom.hex(32)
  end

  def runner_must_belong_to_same_account
    return unless runner && account

    runner_account_id = runner.user&.account_id
    return if runner_account_id == account_id

    errors.add(:runner, "must belong to the same account")
  end

  def project_must_belong_to_same_account
    return unless project && account

    return if project.account_id == account_id

    errors.add(:project, "must belong to the same account")
  end

  def broadcast_sidebar_prepend
    Turbo::StreamsChannel.broadcast_remove_to(
      [ account, :chat_sessions ],
      target: sidebar_empty_state_target
    )
    Turbo::StreamsChannel.broadcast_prepend_to(
      [ account, :chat_sessions ],
      target: sidebar_list_target,
      partial: "chat_sessions/session_card",
      locals: { chat_session: self }
    )
  end

  def broadcast_sidebar_refresh
    previous_status = saved_change_to_status&.first || status

    Turbo::StreamsChannel.broadcast_remove_to(
      [ account, :chat_sessions ],
      target: ActionView::RecordIdentifier.dom_id(self)
    )
    broadcast_sidebar_append_empty_state(status: previous_status) if previous_status != status
    broadcast_sidebar_prepend
  end

  def broadcast_sidebar_remove
    Turbo::StreamsChannel.broadcast_remove_to(
      [ account, :chat_sessions ],
      target: ActionView::RecordIdentifier.dom_id(self)
    )
    broadcast_sidebar_append_empty_state(status: status)
  end

  def broadcast_sidebar_append_empty_state(status:)
    return unless self.class.where(account_id: account_id).public_send(status == "archived" ? :archived_only : :visible).none?

    Turbo::StreamsChannel.broadcast_append_to(
      [ account, :chat_sessions ],
      target: sidebar_list_target(status: status),
      partial: "chat_sessions/sidebar_empty_state",
      locals: { archived_view: status == "archived" }
    )
  end
end
