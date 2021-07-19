defmodule Membrane.Core.Bin do
  @moduledoc false
  use Bunch
  use GenServer

  import Membrane.Helper.GenServer

  alias __MODULE__.{LinkingBuffer, State}
  alias Membrane.{CallbackError, Core, ComponentPath, Pad, Sync}
  alias Membrane.Core.{CallbackHandler, Message, Telemetry}
  alias Membrane.Core.Child.{PadController, PadSpecHandler}

  require Membrane.Core.Message
  require Membrane.Logger

  @type options_t :: %{
          name: atom,
          module: module,
          parent: pid,
          user_options: Membrane.Bin.options_t(),
          parent_clock: Membrane.Clock.t(),
          log_metadata: Keyword.t()
        }

  @doc """
  Starts the Bin based on given module and links it to the current
  process.

  Bin options are passed to module's `c:handle_init/1` callback.

  Process options are internally passed to `GenServer.start_link/3`.

  Returns the same values as `GenServer.start_link/3`.
  """
  @spec start_link(options_t, GenServer.options()) :: GenServer.on_start()
  def start_link(options, process_options \\ []) do
    do_start(:start_link, options, process_options)
  end

  @doc """
  Works similarly to `start_link/2`, but does not link to the current process.
  """
  @spec start(options_t(), GenServer.options()) :: GenServer.on_start()
  def start(options, process_options \\ []) do
    do_start(:start, options, process_options)
  end

  defp do_start(method, options, process_options) do
    if options.module |> Membrane.Bin.bin?() do
      Membrane.Logger.debug("""
      Bin start link: name: #{inspect(options.name)}
      module: #{inspect(options.module)},
      bin options: #{inspect(options.user_options)},
      process options: #{inspect(process_options)}
      """)

      apply(GenServer, method, [Membrane.Core.Bin, options, process_options])
    else
      raise """
      Cannot start bin, passed module #{inspect(options.module)} is not a Membrane Bin.
      Make sure that given module is the right one and it uses Membrane.Bin
      """
    end
  end

  @doc """
  Changes bin's playback state to `:stopped` and terminates its process
  """
  @spec stop_and_terminate(bin :: pid) :: :ok
  def stop_and_terminate(bin) do
    Message.send(bin, :stop_and_terminate)
    :ok
  end

  @impl GenServer
  def init(options) do
    Process.monitor(options.parent)

    %{name: name, module: module, log_metadata: log_metadata} = options
    name_str = if String.valid?(name), do: name, else: inspect(name)
    :ok = Membrane.Logger.set_prefix(name_str <> " bin")
    Logger.metadata(log_metadata)
    :ok = ComponentPath.set_and_append(log_metadata[:parent_path] || [], name_str <> " bin")

    Telemetry.report_init(:bin)

    clock_proxy = Membrane.Clock.start_link(proxy: true) ~> ({:ok, pid} -> pid)
    clock = if Bunch.Module.check_behaviour(module, :membrane_clock?), do: clock_proxy, else: nil

    state =
      %State{
        module: module,
        name: name,
        synchronization: %{
          parent_clock: options.parent_clock,
          timers: %{},
          clock: clock,
          clock_provider: %{clock: nil, provider: nil, choice: :auto},
          clock_proxy: clock_proxy,
          # This is a sync for siblings. This is not yet allowed.
          stream_sync: Sync.no_sync(),
          latency: 0
        },
        children_log_metadata: log_metadata
      }
      |> PadSpecHandler.init_pads()

    with {:ok, state} <-
           CallbackHandler.exec_and_handle_callback(
             :handle_init,
             Membrane.Core.Bin.ActionHandler,
             %{state: false},
             [options.user_options],
             state
           ) do
      {:ok, state}
    else
      {{:error, reason}, _state} ->
        raise CallbackError, kind: :error, callback: {module, :handle_init}, reason: reason

      {other, _state} ->
        raise CallbackError, kind: :bad_return, callback: {module, :handle_init}, value: other
    end
  end

  @impl GenServer
  # Bin-specific message.
  # This forwards all :demand, :caps, :buffer, :event
  # messages to an appropriate element.
  def handle_info(Message.new(type, _args, for_pad: pad) = msg, state)
      when type in [:demand, :caps, :buffer, :event, :push_mode_announcement] do
    outgoing_pad =
      pad
      |> Pad.get_corresponding_bin_pad()

    LinkingBuffer.store_or_send(msg, outgoing_pad, state)
    ~> {:ok, &1}
    |> noreply()
  end

  @impl GenServer
  def handle_info(Message.new(:handle_unlink, pad_ref), state) do
    PadController.handle_pad_removed(pad_ref, state)
    |> noreply()
  end

  @impl GenServer
  def handle_info(message, state) do
    Core.Parent.MessageDispatcher.handle_message(message, state)
  end

  @impl GenServer
  def handle_call(Message.new(:set_controlling_pid, pid), _from, state) do
    Core.Child.LifecycleController.handle_controlling_pid(pid, state)
    |> reply()
  end

  @impl GenServer
  def handle_call(Message.new(:handle_link, [direction, this, other, other_info]), _from, state) do
    PadController.handle_link(direction, this, other, other_info, state) |> reply()
  end

  @impl GenServer
  def handle_call(Message.new(:linking_finished), _from, state) do
    PadController.handle_linking_finished(state)
    |> reply()
  end

  @impl GenServer
  def handle_call(Message.new(:handle_watcher, watcher), _from, state) do
    Core.Child.LifecycleController.handle_watcher(watcher, state)
    |> reply()
  end

  @impl GenServer
  def terminate(reason, state) do
    Telemetry.report_terminate(:bin)

    :ok = state.module.handle_shutdown(reason, state.internal_state)
  end
end
