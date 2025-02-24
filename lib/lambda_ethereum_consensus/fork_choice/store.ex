defmodule LambdaEthereumConsensus.ForkChoice.Store do
  @moduledoc """
    The Store is responsible for tracking information required for the fork choice algorithm.
  """

  use GenServer
  require Logger

  alias LambdaEthereumConsensus.ForkChoice.{Handlers, Helpers}
  alias LambdaEthereumConsensus.Store.{BlockStore, StateStore}
  alias SszTypes.Attestation
  alias SszTypes.BeaconState
  alias SszTypes.SignedBeaconBlock
  alias SszTypes.Store

  ##########################
  ### Public API
  ##########################

  @spec start_link([BeaconState.t()]) :: :ignore | {:error, any} | {:ok, pid}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec get_finalized_checkpoint() :: {:ok, SszTypes.Checkpoint.t()}
  def get_finalized_checkpoint do
    [finalized_checkpoint] = get_store_attrs([:finalized_checkpoint])
    {:ok, finalized_checkpoint}
  end

  @spec get_current_slot() :: integer()
  def get_current_slot do
    [time, genesis_time] = get_store_attrs([:time, :genesis_time])
    div(time - genesis_time, ChainSpec.get("SECONDS_PER_SLOT"))
  end

  @spec has_block?(SszTypes.root()) :: boolean()
  def has_block?(block_root) do
    [blocks] = get_store_attrs([:blocks])
    Map.has_key?(blocks, block_root)
  end

  @spec on_block(SszTypes.SignedBeaconBlock.t(), SszTypes.root()) :: :ok | :error
  def on_block(signed_block, block_root) do
    :ok = BlockStore.store_block(signed_block)
    GenServer.call(__MODULE__, {:on_block, block_root, signed_block})
  end

  @spec on_attestation(SszTypes.Attestation.t()) :: :ok
  def on_attestation(%Attestation{} = attestation) do
    GenServer.cast(__MODULE__, {:on_attestation, attestation})
  end

  @spec notify_attester_slashing(SszTypes.AttesterSlashing.t()) :: :ok
  def notify_attester_slashing(attester_slashing) do
    GenServer.cast(__MODULE__, {:attester_slashing, attester_slashing})
  end

  ##########################
  ### GenServer Callbacks
  ##########################

  @impl GenServer
  @spec init({BeaconState.t(), SignedBeaconBlock.t()}) :: {:ok, Store.t()} | {:stop, any}
  def init({anchor_state = %BeaconState{}, signed_anchor_block = %SignedBeaconBlock{}}) do
    result =
      case Helpers.get_forkchoice_store(anchor_state, signed_anchor_block.message) do
        {:ok, store = %Store{}} ->
          store = on_tick_now(store)
          Logger.info("[Fork choice] Initialized store.")
          {:ok, store}

        {:error, error} ->
          {:stop, error}
      end

    # TODO: this should be done after validation
    :ok = StateStore.store_state(anchor_state)
    :ok = BlockStore.store_block(signed_anchor_block)
    schedule_next_tick()
    result
  end

  @impl GenServer
  def handle_call({:get_store_attrs, attrs}, _from, state) do
    values = Enum.map(attrs, &Map.fetch!(state, &1))
    {:reply, values, state}
  end

  @impl GenServer
  def handle_call({:on_block, _block_root, %SignedBeaconBlock{} = signed_block}, _from, state) do
    Logger.info("[Fork choice] Adding block #{signed_block.message.slot} to the store.")

    case Handlers.on_block(state, signed_block) do
      {:ok, new_state} ->
        BlockStore.store_block(signed_block)
        {:reply, :ok, new_state}

      {:error, reason} ->
        Logger.error(
          "[Fork choice] Failed to add block #{signed_block.message.slot} to the store: #{reason}"
        )

        {:reply, :error, state}
    end

    # TODO: uncomment when fixed
    # with {:ok, new_store} <- Handlers.on_block(state, signed_block) do
    #    # process block attestations
    #    {:ok, new_state} <-
    #      signed_block.message.body.attestations
    #      |> apply_handler(new_state, &Handlers.on_attestation(&1, &2, true)),
    #    # process block attester slashings
    #    {:ok, new_state} <-
    #      signed_block.message.body.attester_slashings
    #      |> apply_handler(new_state, &Handlers.on_attester_slashing/2) do
    #   BlockStore.store_block(signed_block)
    #   {:reply, :ok, new_store}
    # else
    #   {:error, reason} ->
    #     Logger.error(
    #       "[Fork choice] Failed to add block #{signed_block.message.slot} to the store: #{reason}"
    #     )
    #     {:reply, :error, state}
    # end
  end

  @impl GenServer
  def handle_cast({:on_attestation, %Attestation{} = attestation}, %SszTypes.Store{} = state) do
    id = attestation.signature |> Base.encode16() |> String.slice(0, 8)
    Logger.debug("[Fork choice] Adding attestation #{id} to the store.")

    state =
      case Handlers.on_attestation(state, attestation, false) do
        {:ok, new_state} -> new_state
        _ -> state
      end

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:attester_slashing, attester_slashing}, state) do
    Logger.info("[Fork choice] Adding attester slashing to the store.")

    state =
      case Handlers.on_attester_slashing(state, attester_slashing) do
        {:ok, new_state} ->
          new_state

        _ ->
          Logger.error("[Fork choice] Failed to add attester slashing to the store.")
          state
      end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:on_tick, store) do
    new_store = on_tick_now(store)

    schedule_next_tick()
    {:noreply, new_store}
  end

  ##########################
  ### Private Functions
  ##########################

  @spec get_store_attrs([atom()]) :: [any()]
  defp get_store_attrs(attrs) do
    GenServer.call(__MODULE__, {:get_store_attrs, attrs})
  end

  defp on_tick_now(store), do: Handlers.on_tick(store, :os.system_time(:second))

  defp schedule_next_tick do
    # For millisecond precision
    time_to_next_tick = 1000 - rem(:os.system_time(:millisecond), 1000)
    Process.send_after(self(), :on_tick, time_to_next_tick)
  end

  def apply_handler(iter, state, handler) do
    iter
    |> Enum.reduce_while({:ok, state}, fn
      x, {:ok, st} -> {:cont, handler.(st, x)}
      _, {:error, _} = err -> {:halt, err}
    end)
  end
end
