# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule SpillwayWeb.Router do
  use SpillwayWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", SpillwayWeb do
    pipe_through :api

    post "/jobs", JobController, :create
    get "/jobs/:id", JobController, :show
    post "/pools/:pool_id/members", PoolController, :register_member
    get "/health", HealthController, :index
    get "/ready", HealthController, :ready
    get "/.well-known/l8", L8Controller, :well_known
    post "/l8/challenge", L8Controller, :challenge
    get "/l8-spec", L8Controller, :spec
  end

  scope "/", SpillwayWeb do
    get "/jobs/:id/stream", JobStreamController, :stream
    get "/websocket", WebSocketController, :connect
    # Own scope, not the :api pipeline's plug :accepts, ["json"] -- like
    # the stream route above, a fallback response here is
    # text/event-stream, not JSON.
    post "/proxy", JobController, :proxy
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:spillway, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: SpillwayWeb.Telemetry
    end
  end
end
