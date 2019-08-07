defmodule Membrane.Pipeline do
  @moduledoc """
  Module containing functions for constructing and supervising pipelines.

  Pipelines are units that make it possible to instantiate, link and manage
  elements in convenient way (actually elements should always be used inside
  a pipeline). Linking elements together enables them to pass data to one another,
  and process it in different ways.
  """

  alias __MODULE__.{Link, State, Spec}
  alias Membrane.{CallbackError, Core, Element, Notification, PipelineError}
  alias Element.Pad
  alias Core.{Message, Playback}
  alias Bunch.Type
  import Membrane.Helper.GenServer
  require Element
  require Membrane.PlaybackState
  require Message
  require Pad
  use Bunch
  use Membrane.Log, tags: :core
  use Membrane.Core.CallbackHandler
  use GenServer
  use Membrane.Core.PlaybackHandler

  @typedoc """
  Defines options that can be passed to `start/3` / `start_link/3` and received
  in `c:handle_init/1` callback.
  """
  @type pipeline_options_t :: any

  @typedoc """
  Action that sends a message to element identified by name.
  """
  @type forward_action_t :: {:forward, {Element.name_t(), Notification.t()}}

  @typedoc """
  Action that instantiates elements and links them according to `Membrane.Pipeline.Spec`.

  Elements playback state is changed to the current pipeline state.
  `c:handle_spec_started` callback is executed once it happens.
  """
  @type spec_action_t :: {:spec, Spec.t()}

  @typedoc """
  Action that stops, unlinks and removes specified child/children from pipeline.
  """
  @type remove_child_action_t :: {:remove_child, Element.name_t() | [Element.name_t()]}

  @typedoc """
  Type describing actions that can be returned from pipeline callbacks.

  Returning actions is a way of pipeline interaction with its elements and
  other parts of framework.
  """
  @type action_t :: forward_action_t | spec_action_t | remove_child_action_t

  @typedoc """
  Type that defines all valid return values from most callbacks.
  """
  @type callback_return_t :: CallbackHandler.callback_return_t(action_t, State.internal_state_t())

  @typep parsed_child_t :: %{name: Element.name_t(), module: module, options: Keyword.t()}

  @doc """
  Enables to check whether module is membrane pipeline
  """
  @callback membrane_pipeline? :: true

  @doc """
  Callback invoked on initialization of pipeline process. It should parse options
  and initialize element internal state. Internally it is invoked inside
  `c:GenServer.init/1` callback.
  """
  @callback handle_init(options :: pipeline_options_t) ::
              {{:ok, Spec.t()}, State.internal_state_t()}
              | {:error, any}

  @doc """
  Callback invoked when pipeline transition from `:stopped` to `:prepared` state has finished,
  that is all of its elements are prepared to enter `:playing` state.
  """
  @callback handle_stopped_to_prepared(state :: State.internal_state_t()) :: callback_return_t

  @doc """
  Callback invoked when pipeline transition from `:playing` to `:prepared` state has finished,
  that is all of its elements are prepared to be stopped.
  """
  @callback handle_playing_to_prepared(state :: State.internal_state_t()) :: callback_return_t

  @doc """
  Callback invoked when pipeline is in `:playing` state, i.e. all its elements
  are in this state.
  """
  @callback handle_prepared_to_playing(state :: State.internal_state_t()) :: callback_return_t

  @doc """
  Callback invoked when pipeline is in `:playing` state, i.e. all its elements
  are in this state.
  """
  @callback handle_prepared_to_stopped(state :: State.internal_state_t()) :: callback_return_t

  @doc """
  Callback invoked when a notification comes in from an element.
  """
  @callback handle_notification(
              notification :: Notification.t(),
              element :: Element.name_t(),
              state :: State.internal_state_t()
            ) :: callback_return_t

  @doc """
  Callback invoked when pipeline receives a message that is not recognized
  as an internal membrane message.

  Useful for receiving ticks from timer, data sent from NIFs or other stuff.
  """
  @callback handle_other(message :: any, state :: State.internal_state_t()) :: callback_return_t

  @doc """
  Callback invoked when `Membrane.Pipeline.Spec` is linked and in the same playback
  state as pipeline.

  Spec can be started from `c:handle_init/1` callback or as `t:spec_action_t/0`
  action.
  """
  @callback handle_spec_started(elements :: [Element.name_t()], state :: State.internal_state_t()) ::
              callback_return_t

  @doc """
  Starts the Pipeline based on given module and links it to the current
  process.

  Pipeline options are passed to module's `c:handle_init/1` callback.

  Process options are internally passed to `GenServer.start_link/3`.

  Returns the same values as `GenServer.start_link/3`.
  """
  @spec start_link(
          module,
          pipeline_options :: pipeline_options_t,
          process_options :: GenServer.options()
        ) :: GenServer.on_start()
  def start_link(module, pipeline_options \\ nil, process_options \\ []),
    do: do_start(:start_link, module, pipeline_options, process_options)

  @doc """
  Does the same as `start_link/3` but starts process outside of supervision tree.
  """
  @spec start(
          module,
          pipeline_options :: pipeline_options_t,
          process_options :: GenServer.options()
        ) :: GenServer.on_start()
  def start(module, pipeline_options \\ nil, process_options \\ []),
    do: do_start(:start, module, pipeline_options, process_options)

  defp do_start(method, module, pipeline_options, process_options) do
    with :ok <-
           (if module |> pipeline? do
              :ok
            else
              :not_pipeline
            end) do
      debug("""
      Pipeline start link: module: #{inspect(module)},
      pipeline options: #{inspect(pipeline_options)},
      process options: #{inspect(process_options)}
      """)

      apply(GenServer, method, [__MODULE__, {module, pipeline_options}, process_options])
    else
      :not_pipeline ->
        warn_error(
          """
          Cannot start pipeline, passed module #{inspect(module)} is not a Membrane Pipeline.
          Make sure that given module is the right one and it uses Membrane.Pipeline
          """,
          {:not_pipeline, module}
        )
    end
  end

  @doc """
  Changes pipeline's playback state to `:stopped` and terminates its process
  """
  @spec stop_and_terminate(pipeline :: pid) :: :ok
  def stop_and_terminate(pipeline) do
    Message.send(pipeline, :stop_and_terminate)
    :ok
  end

  @doc """
  Changes playback state to `:playing`.

  An alias for `change_playback_state/2` with proper state.
  """
  @spec play(pid) :: :ok
  def play(pid), do: change_playback_state(pid, :playing)

  @doc """
  Changes playback state to `:prepared`.

  An alias for `change_playback_state/2` with proper state.
  """
  @spec prepare(pid) :: :ok
  def prepare(pid), do: change_playback_state(pid, :prepared)

  @doc """
  Changes playback state to `:stopped`.

  An alias for `change_playback_state/2` with proper state.
  """
  @spec stop(pid) :: :ok
  def stop(pid), do: change_playback_state(pid, :stopped)

  @spec change_playback_state(pid, Membrane.PlaybackState.t()) :: :ok
  defp change_playback_state(pid, new_state)
       when Membrane.PlaybackState.is_playback_state(new_state) do
    alias Membrane.Core.Message
    require Message
    Message.send(pid, :change_playback_state, new_state)
    :ok
  end

  @impl GenServer
  def init(module) when is_atom(module) do
    init({module, module |> Bunch.Module.struct()})
  end

  def init(%module{} = pipeline_options) do
    init({module, pipeline_options})
  end

  def init({module, pipeline_options}) do
    with {{:ok, spec}, internal_state} <- module.handle_init(pipeline_options) do
      state = %State{internal_state: internal_state, module: module}
      Message.self(:pipeline_spec, spec)
      {:ok, state}
    else
      {:error, reason} ->
        raise CallbackError, kind: :error, callback: {module, :handle_init}, reason: reason

      other ->
        raise CallbackError, kind: :bad_return, callback: {module, :handle_init}, value: other
    end
  end

  @doc """
  Checks whether module is a pipeline.
  """
  @spec pipeline?(module) :: boolean
  def pipeline?(module) do
    module |> Bunch.Module.check_behaviour(:membrane_pipeline?)
  end

  @spec handle_spec(Spec.t(), State.t()) :: Type.stateful_try_t([Element.name_t()], State.t())
  defp handle_spec(%Spec{children: children_spec, links: links}, state) do
    debug("""
    Initializing pipeline spec
    children: #{inspect(children_spec)}
    links: #{inspect(links)}
    """)

    parsed_children = children_spec |> parse_children

    {:ok, state} = {parsed_children |> check_if_children_names_unique(state), state}
    children = parsed_children |> start_children
    {:ok, state} = children |> add_children(state)
    {{:ok, links}, state} = {links |> parse_links, state}
    links = links |> resolve_links(state)
    {:ok, state} = {links |> link_children(state), state}
    {children_names, children_pids} = children |> Enum.unzip()
    {:ok, state} = {children_pids |> set_children_watcher, state}
    {:ok, state} = exec_handle_spec_started(children_names, state)

    children_pids
    |> Enum.each(&change_playback_state(&1, state.playback.state))

    debug("""
    Initialized pipeline spec
    children: #{inspect(children)}
    children pids: #{inspect(children)}
    links: #{inspect(links)}
    """)

    {{:ok, children_names}, state}
  end

  @spec parse_children(Spec.children_spec_t() | any) :: [parsed_child_t]
  defp parse_children(children) when is_map(children) or is_list(children),
    do: children |> Enum.map(&parse_child/1)

  defp parse_child({name, %module{} = options})
       when Element.is_element_name(name) do
    %{name: name, module: module, options: options}
  end

  defp parse_child({name, module})
       when Element.is_element_name(name) and is_atom(module) do
    options = module |> Bunch.Module.struct()
    %{name: name, module: module, options: options}
  end

  defp parse_child(config) do
    raise PipelineError, "Invalid children config: #{inspect(config, pretty: true)}"
  end

  @spec check_if_children_names_unique([parsed_child_t], State.t()) :: Type.try_t()
  defp check_if_children_names_unique(children, state) do
    children
    |> Enum.map(& &1.name)
    |> Kernel.++(State.get_children_names(state))
    |> Bunch.Enum.duplicates()
    ~> (
      [] ->
        :ok

      duplicates ->
        raise PipelineError, "Duplicated names in children specification: #{inspect(duplicates)}"
    )
  end

  # Starts children based on given specification and links them to the current
  # process in the supervision tree.
  #
  # Please note that this function is not atomic and in case of error there's
  # a chance that some of children will remain running.
  @spec start_children([parsed_child_t]) :: [State.child_t()]
  defp start_children(children) do
    debug("Starting children: #{inspect(children)}")

    children |> Enum.map(&start_child/1)
  end

  # Recursion that starts children processes, case when both module and options
  # are provided.
  defp start_child(%{name: name, module: module, options: options}) do
    debug("Pipeline: starting child: name: #{inspect(name)}, module: #{inspect(module)}")

    with {:ok, pid} <- Element.start_link(self(), module, name, options),
         :ok <- Element.set_controlling_pid(pid, self()) do
      {name, pid}
    else
      {:error, reason} ->
        raise PipelineError,
              "Cannot start child #{inspect(name)}, \
              reason: #{inspect(reason, pretty: true)}"
    end
  end

  @spec add_children([parsed_child_t], State.t()) :: Type.stateful_try_t(State.t())
  defp add_children(children, state) do
    children
    |> Bunch.Enum.try_reduce(state, fn {name, pid}, state ->
      state |> State.add_child(name, pid)
    end)
  end

  @spec parse_links(Spec.links_spec_t() | any) :: Type.try_t([Link.t()])
  defp parse_links(links), do: links |> Bunch.Enum.try_map(&Link.parse/1)

  @spec resolve_links([Link.t()], State.t()) :: [Link.resolved_t()]
  defp resolve_links(links, state) do
    links
    |> Enum.map(fn %{from: from, to: to} = link ->
      %{link | from: from |> resolve_link(state), to: to |> resolve_link(state)}
    end)
  end

  defp resolve_link(%{element: element, pad_name: pad_name, id: id} = endpoint, state) do
    with {:ok, pid} <- state |> State.get_child_pid(element),
         {:ok, pad_ref} <- pid |> Message.call(:get_pad_ref, [pad_name, id]) do
      %{endpoint | pid: pid, pad_ref: pad_ref}
    else
      {:error, {:unknown_child, child}} ->
        raise PipelineError, "Child #{inspect(child)} does not exist"

      {:error, {:cannot_handle_message, :unknown_pad, _ctx}} ->
        raise PipelineError, "Child #{inspect(element)} does not have pad #{inspect(pad_name)}"

      {:error, reason} ->
        raise PipelineError, """
        Error resolving pad #{inspect(pad_name)} of element #{inspect(element)}, \
        reason: #{inspect(reason, pretty: true)}\
        """
    end
  end

  # Links children based on given specification and map for mapping children
  # names into PIDs.
  #
  # Please note that this function is not atomic and in case of error there's
  # a chance that some of children will remain linked.
  @spec link_children([Link.resolved_t()], State.t()) :: Type.try_t()
  defp link_children(links, state) do
    debug("Linking children: links = #{inspect(links)}")

    with :ok <- links |> Bunch.Enum.try_each(&Element.link/1),
         :ok <-
           state
           |> State.get_children()
           |> Bunch.Enum.try_each(fn {_pid, pid} -> pid |> Element.handle_linking_finished() end),
         do: :ok
  end

  @spec set_children_watcher([pid]) :: :ok
  defp set_children_watcher(elements_pids) do
    elements_pids
    |> Enum.each(fn pid ->
      :ok = pid |> Element.set_watcher(self())
    end)

    :ok
  end

  @spec exec_handle_spec_started([Element.name_t()], State.t()) :: {:ok, State.t()}
  defp exec_handle_spec_started(children_names, state) do
    callback_res =
      CallbackHandler.exec_and_handle_callback(
        :handle_spec_started,
        __MODULE__,
        [children_names],
        state
      )

    with {:ok, _} <- callback_res do
      callback_res
    else
      {{:error, reason}, state} ->
        raise PipelineError, """
        Callback :handle_spec_started failed with reason: #{inspect(reason)}
        Pipeline state: #{inspect(state, pretty: true)}
        """
    end
  end

  @impl PlaybackHandler
  def handle_playback_state(_old, new, state) do
    children_pids = state |> State.get_children() |> Map.values()

    children_pids
    |> Enum.each(&change_playback_state(&1, new))

    state = %{state | pending_pids: children_pids |> MapSet.new()}
    PlaybackHandler.suspend_playback_change(state)
  end

  @impl PlaybackHandler
  def handle_playback_state_changed(_old, :stopped, %State{terminating?: true} = state) do
    Message.self(:stop_and_terminate)
    {:ok, state}
  end

  def handle_playback_state_changed(_old, _new, state), do: {:ok, state}

  @impl GenServer
  def handle_info(
        Message.new(:playback_state_changed, [_pid, _new_playback_state]),
        %State{pending_pids: pending_pids} = state
      )
      when pending_pids == %MapSet{} do
    {:ok, state} |> noreply
  end

  def handle_info(
        Message.new(:playback_state_changed, [_pid, new_playback_state]),
        %State{playback: %Playback{pending_state: pending_playback_state}} = state
      )
      when new_playback_state != pending_playback_state do
    {:ok, state} |> noreply
  end

  def handle_info(
        Message.new(:playback_state_changed, [pid, new_playback_state]),
        %State{playback: %Playback{state: current_playback_state}, pending_pids: pending_pids} =
          state
      ) do
    new_pending_pids = pending_pids |> MapSet.delete(pid)
    new_state = %{state | pending_pids: new_pending_pids}

    if new_pending_pids != pending_pids and new_pending_pids |> Enum.empty?() do
      callback = PlaybackHandler.state_change_callback(current_playback_state, new_playback_state)

      with {:ok, new_state} <-
             CallbackHandler.exec_and_handle_callback(callback, __MODULE__, [], new_state) do
        PlaybackHandler.continue_playback_change(__MODULE__, new_state)
      else
        error -> error
      end
    else
      {:ok, new_state}
    end
    |> noreply(new_state)
  end

  def handle_info(Message.new(:change_playback_state, new_state), state) do
    PlaybackHandler.change_playback_state(new_state, __MODULE__, state) |> noreply(state)
  end

  def handle_info(Message.new(:stop_and_terminate), state) do
    case state.playback.state do
      :stopped ->
        {:stop, :normal, state}

      _ ->
        state = %{state | terminating?: true}

        PlaybackHandler.change_and_lock_playback_state(:stopped, __MODULE__, state)
        |> noreply(state)
    end
  end

  def handle_info(Message.new(:pipeline_spec, spec), state) do
    with {{:ok, _children}, state} <- spec |> handle_spec(state) do
      {:ok, state}
    end
    |> noreply(state)
  end

  def handle_info(Message.new(:notification, [from, notification]), state) do
    with {:ok, _} <- state |> State.get_child_pid(from) do
      CallbackHandler.exec_and_handle_callback(
        :handle_notification,
        __MODULE__,
        [notification, from],
        state
      )
    end
    |> noreply(state)
  end

  def handle_info(Message.new(:shutdown_ready, child), state) do
    {{:ok, pid}, state} = State.pop_child(state, child)
    {Element.shutdown(pid), state}
  end

  def handle_info(message, state) do
    CallbackHandler.exec_and_handle_callback(:handle_other, __MODULE__, [message], state)
    |> noreply(state)
  end

  @impl CallbackHandler
  def handle_action({:forward, {elementname, message}}, _cb, _params, state) do
    with {:ok, pid} <- state |> State.get_child_pid(elementname) do
      send(pid, message)
      {:ok, state}
    else
      {:error, reason} ->
        {{:error, {:cannot_forward_message, [element: elementname, message: message], reason}},
         state}
    end
  end

  def handle_action({:spec, spec = %Spec{}}, _cb, _params, state) do
    with {{:ok, _children}, state} <- handle_spec(spec, state), do: {:ok, state}
  end

  def handle_action({:remove_child, children}, _cb, _params, state) do
    with {:ok, pids} <-
           children |> Bunch.listify() |> Bunch.Enum.try_map(&State.get_child_pid(state, &1)) do
      pids |> Enum.each(&Message.send(&1, :prepare_shutdown))
      :ok
    end
    ~> {&1, state}
  end

  def handle_action(action, callback, _params, state) do
    raise CallbackError, kind: :invalid_action, action: action, callback: {state.module, callback}
  end

  defmacro __using__(_) do
    quote location: :keep do
      alias unquote(__MODULE__)
      @behaviour unquote(__MODULE__)

      @doc """
      Starts the pipeline `#{inspect(__MODULE__)}` and links it to the current process.

      A proxy for `Membrane.Pipeline.start_link/3`
      """
      @spec start_link(
              pipeline_options :: Pipeline.pipeline_options_t(),
              process_options :: GenServer.options()
            ) :: GenServer.on_start()
      def start_link(pipeline_options \\ nil, process_options \\ []) do
        Pipeline.start_link(__MODULE__, pipeline_options, process_options)
      end

      @doc """
      Starts the pipeline `#{inspect(__MODULE__)}` without linking it
      to the current process.

      A proxy for `Membrane.Pipeline.start/3`
      """
      @spec start(
              pipeline_options :: Pipeline.pipeline_options_t(),
              process_options :: GenServer.options()
            ) :: GenServer.on_start()
      def start(pipeline_options \\ nil, process_options \\ []) do
        Pipeline.start(__MODULE__, pipeline_options, process_options)
      end

      @doc """
      Changes playback state of pipeline to `:playing`

      A proxy for `Membrane.Pipeline.play/1`
      """
      @spec play(pid()) :: :ok
      defdelegate play(pipeline), to: Pipeline

      @doc """
      Changes playback state to `:prepared`.

      A proxy for `Membrane.Pipeline.prepare/1`
      """
      @spec prepare(pid) :: :ok
      defdelegate prepare(pipeline), to: Pipeline

      @doc """
      Changes playback state to `:stopped`.

      A proxy for `Membrane.Pipeline.stop/1`
      """
      @spec stop(pid) :: :ok
      defdelegate stop(pid), to: Pipeline

      @doc """
      Changes pipeline's playback state to `:stopped` and terminates its process.

      A proxy for `Membrane.Pipeline.stop_and_terminate/1`
      """
      @spec stop_and_terminate(pid) :: :ok
      defdelegate stop_and_terminate(pipeline), to: Pipeline

      @impl true
      def membrane_pipeline?, do: true

      @impl true
      def handle_init(_options), do: {{:ok, %Pipeline.Spec{}}, %{}}

      @impl true
      def handle_stopped_to_prepared(state), do: {:ok, state}

      @impl true
      def handle_playing_to_prepared(state), do: {:ok, state}

      @impl true
      def handle_prepared_to_playing(state), do: {:ok, state}

      @impl true
      def handle_prepared_to_stopped(state), do: {:ok, state}

      @impl true
      def handle_notification(_notification, _from, state), do: {:ok, state}

      @impl true
      def handle_other(_message, state), do: {:ok, state}

      @impl true
      def handle_spec_started(_new_children, state), do: {:ok, state}

      defoverridable start: 0,
                     start: 1,
                     start: 2,
                     start_link: 0,
                     start_link: 1,
                     start_link: 2,
                     play: 1,
                     prepare: 1,
                     stop: 1,
                     handle_init: 1,
                     handle_stopped_to_prepared: 1,
                     handle_playing_to_prepared: 1,
                     handle_prepared_to_playing: 1,
                     handle_prepared_to_stopped: 1,
                     handle_notification: 3,
                     handle_other: 2,
                     handle_spec_started: 2
    end
  end
end
