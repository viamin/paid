# frozen_string_literal: true

defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MyAppWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug MyAppWeb.Plug.FetchCurrentUser
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", MyAppWeb do
    pipe_through :browser

    get "/", PageController, :index
    live "/dashboard", DashboardLive, :index
    resources "/reports", ReportController
  end

  scope "/admin", MyAppWeb.Admin do
    pipe_through :browser

    get "/", AdminController, :index
    resources "/users", UserController
  end

  scope "/api", MyAppWeb.Api do
    pipe_through :api

    resources "/widgets", WidgetController, only: [:index, :show]
  end
end