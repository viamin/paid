defmodule ColorMatchingWeb.Router do
  use ColorMatchingWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {ColorMatchingWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :fetch_current_scope_for_user
  end

  pipeline :require_authenticated_user do
    plug :require_authenticated_user
  end

  scope "/", ColorMatchingWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/match", MatchLive, :index
    post "/palette", PaletteController, :create
    resources "/swatches", SwatchController, only: [:index, :show]
    get "/users/log_in", UserSessionController, :new
  end

  scope "/admin", ColorMatchingWeb do
    pipe_through [:browser, :require_authenticated_user]

    live "/dashboard", AdminDashboardLive, :index
  end
end
