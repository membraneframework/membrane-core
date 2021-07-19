defmodule Membrane.Core.Pipeline do
  @moduledoc false
  use GenServer

  alias __MODULE__.{ActionHandler, State}
  alias Membrane.Clock
  alias Membrane.Core.CallbackHandler
  alias Membrane.Core.Parent.MessageDispatcher
  alias Membrane.Core.Telemetry

  require Membrane.Logger

  @impl GenServer
  def init({module, pipeline_options}) do
    pipeline_name = "pipeline@#{:erlang.pid_to_list(self())}"
    :ok = Membrane.ComponentPath.set([pipeline_name])
    :ok = Membrane.Logger.set_prefix(pipeline_name)

    Telemetry.report_init(:pipeline)

    {:ok, clock} = Clock.start_link(proxy: true)

    state = %State{
      module: module,
      synchronization: %{
        clock_proxy: clock,
        clock_provider: %{clock: nil, provider: nil, choice: :auto},
        timers: %{}
      }
    }

    with {:ok, state} <-
           CallbackHandler.exec_and_handle_callback(
             :handle_init,
             ActionHandler,
             %{state: false},
             [pipeline_options],
             state
           ) do
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_info(message, state) do
    MessageDispatcher.handle_message(message, state)
  end

  @impl GenServer
  def terminate(reason, state) do
    Telemetry.report_terminate(:pipeline)

    :ok = state.module.handle_shutdown(reason, state.internal_state)
  end
end
