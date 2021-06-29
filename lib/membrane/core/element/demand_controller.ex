defmodule Membrane.Core.Element.DemandController do
  @moduledoc false

  # Module handling demands incoming through output pads.

  use Bunch

  alias Membrane.Core.{CallbackHandler, Message}
  alias Membrane.Core.Child.PadModel
  alias Membrane.Core.Element.{ActionHandler, State}
  alias Membrane.Element.CallbackContext
  alias Membrane.Pad

  require Membrane.Core.Child.PadModel
  require Membrane.Logger

  @doc """
  Handles demand coming on a output pad. Updates demand value and executes `handle_demand` callback.
  """
  @spec handle_demand(Pad.ref_t(), non_neg_integer, State.t()) ::
          State.stateful_try_t()
  def handle_demand(pad_ref, size, state) do
    # IO.inspect({size, state.name}, label: :demand)
    %{direction: :output, demand_pads: demand_pads} = PadModel.get_data!(state, pad_ref)

    cond do
      ignore?(pad_ref, state) -> {:ok, state}
      demand_pads == [] -> do_handle_demand(pad_ref, size, state)
      true -> handle_auto_demand(pad_ref, size, state)
    end
  end

  defp handle_auto_demand(pad_ref, size, state) do
    %{demand: old_demand} = PadModel.get_data!(state, pad_ref)
    state = PadModel.set_data!(state, pad_ref, :demand, old_demand + size)

    if old_demand <= 0 do
      {:ok,
       get_auto_demand_pads_data(pad_ref, state)
       |> Enum.map(& &1.ref)
       |> Enum.reduce(state, &check_auto_demand/2)}
    else
      {:ok, state}
    end

    # {:ok, state}
  end

  def check_auto_demand(pad_ref, state) do
    demand = PadModel.get_data!(state, pad_ref, :demand)
    demand_size = state.demand_size

    if demand <= demand_size / 2 and
         not (get_auto_demand_pads_data(pad_ref, state) |> Enum.all?(&(&1.demand > 0))) do
      IO.inspect(state.name, label: :miss)
    end

    if demand <= demand_size / 2 and
         get_auto_demand_pads_data(pad_ref, state) |> Enum.all?(&(&1.demand > 0)) do
      # if demand <= demand_size / 2 do
      %{pid: pid, other_ref: other_ref} = PadModel.get_data!(state, pad_ref)
      Message.send(pid, :demand, demand_size, for_pad: other_ref)
      PadModel.set_data!(state, pad_ref, :demand, demand + demand_size)
    else
      state
    end
  end

  defp get_auto_demand_pads_data(pad_ref, state) do
    demand_pads = PadModel.get_data!(state, pad_ref, :demand_pads)

    state.pads.data
    |> Map.values()
    |> Enum.filter(&(&1.name in demand_pads))
  end

  @spec ignore?(Pad.ref_t(), State.t()) :: boolean()
  defp ignore?(pad_ref, state), do: state.pads.data[pad_ref].mode == :push

  @spec do_handle_demand(Pad.ref_t(), non_neg_integer, State.t()) ::
          State.stateful_try_t()
  defp do_handle_demand(pad_ref, size, state) do
    {total_size, state} =
      state
      |> PadModel.get_and_update_data!(pad_ref, :demand, fn demand ->
        (demand + size) ~> {&1, &1}
      end)

    if exec_handle_demand?(pad_ref, state) do
      %{other_demand_unit: unit} = PadModel.get_data!(state, pad_ref)
      require CallbackContext.Demand
      context = &CallbackContext.Demand.from_state(&1, incoming_demand: size)

      CallbackHandler.exec_and_handle_callback(
        :handle_demand,
        ActionHandler,
        %{split_continuation_arbiter: &exec_handle_demand?(pad_ref, &1), context: context},
        [pad_ref, total_size, unit],
        state
      )
    else
      {:ok, state}
    end
  end

  @spec exec_handle_demand?(Pad.ref_t(), State.t()) :: boolean
  defp exec_handle_demand?(pad_ref, state) do
    case PadModel.get_data!(state, pad_ref) do
      %{end_of_stream?: true} ->
        Membrane.Logger.debug_verbose("""
        Demand controller: not executing handle_demand as :end_of_stream action has already been returned
        """)

        false

      %{demand: demand} when demand <= 0 ->
        Membrane.Logger.debug_verbose("""
        Demand controller: not executing handle_demand as demand is not greater than 0,
        demand: #{inspect(demand)}
        """)

        false

      _pad_data ->
        true
    end
  end
end
