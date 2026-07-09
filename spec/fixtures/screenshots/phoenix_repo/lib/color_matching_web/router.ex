defmodule ColorMatchingWeb.Router do
  use ColorMatchingWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ColorMatchingWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :require_authenticated_user do
    plug :require_authenticated_user
  end

  scope "/", ColorMatchingWeb do
    pipe_through [:browser]

    live "/", PaletteLive, :index
    get "/dashboard", DashboardController, :index
    post "/samples", SampleController, :create
    resources "/projects", ProjectController
  end

  scope "/", ColorMatchingWeb do
    pipe_through [:browser, :require_authenticated_user]

    live "/settings", SettingsLive, :edit
    get "/users/log_in", UserSessionController, :new
  end
end
