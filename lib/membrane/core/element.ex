defmodule Membrane.Core.Element do
  @moduledoc false

  # Module containing functions spawning, shutting down, inspecting and controlling
  # playback of elements. These functions are usually called by `Membrane.Pipeline`
  # or `Membrane.Bin`.
  #
  # Modules in this namespace are responsible for managing elements: handling incoming
  # data, executing callbacks and evaluating actions. These modules can be divided
  # in terms of functionality in the following way:
  # - `Membrane.Core.Element.MessageDispatcher` parses incoming messages and
  #   forwards them to controllers and handlers
  # - Controllers handle messages received from other elements or calls from other
  #   controllers and handlers
  # - Handlers handle actions invoked by element itself
  # - Models contain some utility functions for accessing data in state
  # - `Membrane.Core.Element.State` defines the state struct that these modules
  #   operate on.

  use Bunch
  use GenServer

  alias Membrane.{Clock, Element, Sync}
  alias Membrane.Core.Element.{HotPathController, MessageDispatcher, State}
  alias Membrane.Core.Message
  alias Membrane.ComponentPath

  require Membrane.Core.Message
  require Membrane.Logger

  @type options_t :: %{
          module: module,
          name: Element.name_t(),
          user_options: Element.options_t(),
          sync: Sync.t(),
          parent: pid,
          parent_clock: Clock.t(),
          log_metadata: Keyword.t()
        }

  @doc """
  Starts process for element of given module, initialized with given options and
  links it to the current process in the supervision tree.

  Calls `GenServer.start_link/3` underneath.
  """
  @spec start_link(options_t, GenServer.options()) :: GenServer.on_start()
  def start_link(options, process_options \\ []),
    do: do_start(:start_link, options, process_options)

  @doc """
  Works similarly to `start_link/5`, but does not link to the current process.
  """
  @spec start(options_t, GenServer.options()) :: GenServer.on_start()
  def start(options, process_options \\ []),
    do: do_start(:start, options, process_options)

  defp do_start(method, options, process_options) do
    %{module: module, name: name, user_options: user_options} = options

    if Element.element?(options.module) do
      Membrane.Logger.debug("""
      Element #{method}: #{inspect(name)}
      module: #{inspect(module)},
      element options: #{inspect(user_options)},
      process options: #{inspect(process_options)}
      """)

      apply(GenServer, method, [__MODULE__, options, process_options])
    else
      raise """
      Cannot start element, passed module #{inspect(module)} is not a Membrane Element.
      Make sure that given module is the right one and it uses Membrane.{Source | Filter | Sink}
      """
    end
  end

  @doc """
  Stops given element process.

  It will wait for reply for amount of time passed as second argument
  (in milliseconds).

  Will trigger calling `c:Membrane.Element.Base.handle_shutdown/1`
  callback.
  """
  @spec shutdown(pid, timeout) :: :ok
  def shutdown(server, timeout \\ 5000) do
    GenServer.stop(server, :normal, timeout)
    :ok
  end

  @impl GenServer
  def init(options) do
    parent_monitor = Process.monitor(options.parent)
    name_str = if String.valid?(options.name), do: options.name, else: inspect(options.name)
    :ok = Membrane.Logger.set_prefix(name_str)
    Logger.metadata(options.log_metadata)

    :ok = ComponentPath.set_and_append(options.log_metadata[:parent_path] || [], name_str)

    state =
      options
      |> Map.take([:module, :name, :parent_clock, :sync])
      |> Map.put(:parent_monitor, parent_monitor)
      |> State.new()

    with {:ok, state} <-
           MessageDispatcher.handle_message(
             Message.new(:init, options.user_options),
             :other,
             state
           ) do
      {:ok, state}
    else
      {{:error, reason}, _state} -> {:stop, {:element_init, reason}}
    end
  end

  @impl GenServer
  def terminate(reason, state) do
    {:ok, _state} =
      MessageDispatcher.handle_message(Message.new(:shutdown, reason), :other, state)

    :ok
  end

  @impl GenServer
  def handle_call(message, _from, state) do
    message |> MessageDispatcher.handle_message(:call, state)
  end

  @impl GenServer
  def handle_info(Message.new(:buffer, buffers, _opts) = message, state) do
    pad_ref = Message.for_pad(message)

    case HotPathController.handle_buffer(pad_ref, buffers, state) do
      {:match, state} -> {:noreply, state}
      :no_match -> MessageDispatcher.handle_message(message, :info, state)
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{parent_monitor: ref} = state) do
    {:noreply, state} =
      MessageDispatcher.handle_message(Message.new(:pipeline_down, reason), :info, state)

    {:stop, {:shutdown, :parent_crash}, state}
  end

  @impl GenServer
  def handle_info(message, state) do
    message |> MessageDispatcher.handle_message(:info, state)
  end
end
