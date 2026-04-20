# frozen_string_literal: true

class MoveCoAuthorTrailerFromProjectsToProviders < ActiveRecord::Migration[8.1]
  # The trailer moves from the project level to the provider level so that
  # attribution reflects the provider that actually produced the commit,
  # including after provider fallback. :text matches the original column;
  # the trailer is a freeform value (e.g. "Co-Authored-By: Name <email>")
  # with no practical length constraint.
  #
  # Data migration: copy each project's configured trailer onto the project
  # owner's default/subscription provider so deployed values are not silently
  # discarded. Projects sharing an owner may have different trailers; when
  # that happens the most recently updated project's trailer wins. This is
  # lossy (provider is per-user while the trailer used to be per-project),
  # but it preserves the most-recent intent and avoids wiping configuration.

  def up
    add_column :providers, :agent_co_author_trailer, :text unless column_exists?(:providers, :agent_co_author_trailer)

    # Copy project-level trailers onto the owning user's default subscription
    # provider (prefer "claude" when present, otherwise the lowest-id
    # subscription provider). The per-user target is resolved the same way
    # Project#effective_owner falls back — created_by when present, otherwise
    # the account's first owner membership, otherwise the account's first user.
    execute(<<~SQL)
      WITH project_trailers AS (
        SELECT DISTINCT ON (owner_id)
          owner_id,
          trailer
        FROM (
          SELECT
            COALESCE(
              p.created_by_id,
              (
                -- AccountMembership.roles[:owner] == 3; must stay in sync if enum changes.
                SELECT am.user_id
                FROM account_memberships am
                WHERE am.account_id = p.account_id AND am.role = 3
                ORDER BY am.id
                LIMIT 1
              ),
              (
                SELECT u.id
                FROM users u
                WHERE u.account_id = p.account_id
                ORDER BY u.id
                LIMIT 1
              )
            ) AS owner_id,
            p.agent_co_author_trailer AS trailer,
            p.updated_at
          FROM projects p
          WHERE p.agent_co_author_trailer IS NOT NULL
            AND length(btrim(p.agent_co_author_trailer)) > 0
        ) ranked
        WHERE owner_id IS NOT NULL
        ORDER BY owner_id, updated_at DESC, trailer
      ),
      targets AS (
        SELECT DISTINCT ON (pr.user_id)
          pr.id,
          pt.trailer
        FROM providers pr
        JOIN project_trailers pt ON pt.owner_id = pr.user_id
        WHERE pr.auth_type = 'subscription'
        ORDER BY pr.user_id,
                 CASE WHEN pr.provider_key = 'claude' THEN 0 ELSE 1 END,
                 pr.id
      )
      UPDATE providers
      SET agent_co_author_trailer = targets.trailer
      FROM targets
      WHERE providers.id = targets.id
    SQL

    remove_column :projects, :agent_co_author_trailer
  end

  def down
    add_column :projects, :agent_co_author_trailer, :text unless column_exists?(:projects, :agent_co_author_trailer)

    # Best-effort restore: copy each owning user's provider trailer back onto
    # every project the user created. Projects without a created_by are left
    # null because the provider→project mapping is not reconstructible.
    execute(<<~SQL)
      UPDATE projects
      SET agent_co_author_trailer = src.trailer
      FROM (
        SELECT DISTINCT ON (pr.user_id)
          pr.user_id AS user_id,
          pr.agent_co_author_trailer AS trailer
        FROM providers pr
        WHERE pr.agent_co_author_trailer IS NOT NULL
          AND length(btrim(pr.agent_co_author_trailer)) > 0
        ORDER BY pr.user_id,
                 CASE WHEN pr.provider_key = 'claude' THEN 0 ELSE 1 END,
                 pr.id
      ) AS src
      WHERE projects.created_by_id = src.user_id
    SQL

    remove_column :providers, :agent_co_author_trailer
  end
end
