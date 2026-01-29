# frozen_string_literal: true

class User < ApplicationRecord
  rolify

  belongs_to :account
  has_many :created_github_tokens, class_name: "GithubToken", foreign_key: :created_by_id, dependent: :nullify, inverse_of: :created_by
  has_many :created_projects, class_name: "Project", foreign_key: :created_by_id, dependent: :nullify, inverse_of: :created_by

  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  validates :account, presence: true

  after_create :assign_owner_role_if_first_user

  private

  def assign_owner_role_if_first_user
    return unless account.users.count == 1

    add_role(:owner, account)
  end
end
