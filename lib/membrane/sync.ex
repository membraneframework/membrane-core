defmodule Membrane.Sync do
  @moduledoc """
  Sync allows to synchronize multiple processes, so that they could perform their
  jobs at the same time.

  The main purpose for Sync is to synchronize multiple streams within a pipeline.
  The flow of usage goes as follows:
  - A Sync process is started.
  - Processes register themselves (or are registered) in the Sync, using
  `register/2`. Registered processes are not being synchronized till the Sync
  becomes active (see the next step). Each registered process is monitored and
  automatically unregistered upon exit. Sync can be setup to exit when all the
  registered processes exit by passing the `empty_exit?` option to `start_link/2`.
  - When all processes that need to be registered are registered, the Sync can
  be activated with `activate/1` function. This disables registration and enables
  synchronization.
  - Once a process needs to sync, it invokes `sync/2`, which results in blocking
  until all the registered processes invoke `sync/2`. This works only when the Sync
  is active - otherwise calling `sync/2` returns immediately.
  - Once all the ready processes invoke `sync/2`, the calls return, and they become
  registered again.
  - When synchronization needs to be turned off, the Sync should be deactivated
  with `deactivate/2`. This disables synchronization and enables registration again.
  All the calls to `sync/2` return immediately.

  If a process designed to work with Sync should not be synced, `no_sync/0` should
  be used. Then all calls to `sync/2` return immediately.
  """
  use Bunch
  use GenServer
  alias Membrane.Time

  @no_sync :membrane_no_sync

  @type t :: pid | :membrane_sync_no_sync
  @type status_t :: :registered | :sync

  @doc """
  Starts a Sync process linked to the current process.

  ## Options
  - :empty_exit? - if true, Sync automatically exits when all the registered
    processes exit; defaults to false

  """
  @spec start_link([empty_exit?: boolean], GenServer.options()) :: GenServer.on_start()
  def start_link(options \\ [], gen_server_options \\ []) do
    GenServer.start_link(__MODULE__, options, gen_server_options)
  end

  def start_link!(options \\ [], gen_server_options \\ []) do
    {:ok, pid} = start_link(options, gen_server_options)
    pid
  end

  @spec register(t, pid) :: :ok | {:error, :bad_activity_request}
  def register(sync, pid \\ self())

  def register(@no_sync, _pid), do: :ok

  def register(sync, pid) do
    GenServer.call(sync, {:sync_register, pid})
  end

  @spec activate(t) :: :ok | {:error, :bad_activity_request}
  def activate(@no_sync), do: :ok

  def activate(sync) do
    GenServer.call(sync, {:sync_toggle_active, true})
  end

  @spec deactivate(t) :: :ok | {:error, :bad_activity_request}
  def deactivate(@no_sync), do: :ok

  def deactivate(sync) do
    GenServer.call(sync, {:sync_toggle_active, false})
  end

  @spec sync(t) :: :ok | {:error, :not_found}
  def sync(@no_sync), do: :ok

  def sync(sync, options \\ []) do
    GenServer.call(sync, {:sync, options})
  end

  @doc """
  Returns a Sync that always returns immediately when calling `sync/2` on it.
  """
  @spec no_sync() :: t
  def no_sync(), do: @no_sync

  @impl true
  def init(opts) do
    {:ok,
     %{
       processes: %{},
       empty_exit?: opts |> Keyword.get(:empty_exit?, false),
       active?: false
     }}
  end

  @impl true
  def handle_call({:sync_register, pid}, _from, %{active?: false} = state) do
    Process.monitor(pid)
    state = state |> put_in([:processes, pid], %{status: :registered, latency: 0, reply_to: nil})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:sync_register, _pid}, _from, state) do
    {:reply, {:error, :bad_activity_request}, state}
  end

  @impl true
  def handle_call({:sync, options}, {pid, _ref} = from, %{active?: true} = state) do
    latency = options |> Keyword.get(:latency, 0)

    case state.processes[pid] do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: :registered} = syncee ->
        state =
          state
          |> put_in([:processes, pid], %{syncee | status: :sync, latency: latency, reply_to: from})
          |> check_and_handle_sync()

        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:sync, _options}, _from, %{active?: false} = state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:sync_toggle_active, new_active?}, _from, %{active?: active?} = state)
      when new_active? == active? do
    {:reply, {:error, :bad_activity_request}, state}
  end

  @impl true
  def handle_call({:sync_toggle_active, active?}, _from, state) do
    state = %{state | active?: active?} |> check_and_handle_sync()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:reply, to}, state) do
    to |> Enum.each(&GenServer.reply(&1, :ok))
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = state |> Bunch.Access.delete_in([:processes, pid]) |> check_and_handle_sync()

    if state.empty_exit? and state.processes |> Enum.empty?() do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  defp check_and_handle_sync(state) do
    if state.active? and state.processes |> Bunch.KVList.any_value?(&(&1.status != :sync)) do
      state
    else
      send_sync_replies(state.processes)
      state |> reset_processes()
    end
  end

  defp send_sync_replies(processes) do
    processes_data = processes |> Map.values()
    max_latency = processes_data |> Enum.map(& &1.latency) |> Enum.max(fn -> 0 end)

    processes_data
    |> Enum.filter(&(&1.status == :sync))
    |> Enum.group_by(& &1.latency, & &1.reply_to)
    |> Enum.each(fn {latency, reply_to} ->
      time = (max_latency - latency) |> Time.to_milliseconds()
      Process.send_after(self(), {:reply, reply_to}, time)
    end)
  end

  defp reset_processes(state) do
    state
    |> Map.update!(
      :processes,
      &Bunch.Map.map_values(&1, fn s -> %{s | status: :registered} end)
    )
  end
end