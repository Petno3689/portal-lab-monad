// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRandomSource, IRandomConsumer} from "./IRandomSource.sol";

/// @dev Minimal slice of the Pyth Entropy V2 interface — only the two methods
/// this adapter calls. Declared here (not pulled from a Pyth SDK submodule) so
/// the game has no build-time dependency on Pyth; the only coupling is the
/// address passed at deploy. Signatures match `IEntropyV2` (SPEC §6.1).
interface IEntropyV2 {
    /// @notice Flat fee for a request with the given callback gas limit. On Monad
    /// testnet this does not actually vary with the limit (SPEC §6: 0.12816 MON).
    function getFeeV2(address provider, uint32 gasLimit) external view returns (uint128 feeAmount);

    /// @notice Request entropy from `provider`, reserving `gasLimit` gas for the
    /// fulfillment callback. Returns the sequence number that identifies the
    /// request and is echoed back to `entropyCallback`.
    function requestV2(address provider, uint32 gasLimit)
        external
        payable
        returns (uint64 assignedSequenceNumber);
}

/// @dev The Pyth `IEntropyConsumer` base, inlined. Pyth calls `_entropyCallback`
/// (the external entry point); this wrapper proves the caller is the Entropy
/// contract, then hands control to the consumer's `entropyCallback`. Reproduced
/// rather than imported for the same no-SDK-dependency reason as `IEntropyV2`.
abstract contract IEntropyConsumer {
    /// @notice External entry point Pyth calls on fulfillment (matches SDK `_entropyCallback`).
    /// Guarded to the Entropy contract so nobody else can inject a random value (SPEC §6.4).
    function _entropyCallback(uint64 sequence, address provider, bytes32 randomNumber) external {
        if (msg.sender != getEntropy()) revert NotEntropy();
        entropyCallback(sequence, provider, randomNumber);
    }

    /// @dev Reverts `_entropyCallback` when the caller is not the Entropy contract.
    error NotEntropy();

    function getEntropy() internal view virtual returns (address);

    /// @dev Override this to handle the delivered random number. Called by
    /// `_entropyCallback` after the Entropy-contract guard passes.
    function entropyCallback(uint64 sequence, address provider, bytes32 randomNumber) internal virtual;
}

/// @title PythEntropySource — IRandomSource backed by Pyth Entropy V2 (SPEC §6).
/// @notice The ONLY place Pyth types appear. PortalLab talks to it purely through
/// `IRandomSource` / `IRandomConsumer`, so replacing Pyth with another provider is
/// a redeploy of this one contract plus a one-address change in PortalLab — the
/// game is untouched (Ticket 4.4 §1.3).
///
/// @dev Flow:
///   1. PortalLab calls `requestWord{value: fee()}(player)`; we call Pyth
///      `requestV2` with a 1 000 000-gas callback limit (taken in full — the
///      callback gas is prepaid by the flat fee, SPEC §6.1) and remember who asked.
///   2. Pyth fulfils in a later transaction via `_entropyCallback`; we forward the
///      word to the recorded consumer with the same sequence number as the id.
contract PythEntropySource is IRandomSource, IEntropyConsumer {
    /// @notice The Pyth Entropy V2 proxy (SPEC §6.1 — use the proxy, never the
    /// implementation). Set at deploy, never changed.
    IEntropyV2 public immutable entropy;

    /// @notice The entropy provider whose randomness we request. Set at deploy.
    address public immutable provider;

    /// @notice Callback gas limit requested from Pyth. The full million is taken:
    /// it is covered by the flat fee, so there is no reason to ask for less
    /// (Ticket 4.4 §4.4).
    uint32 public constant CALLBACK_GAS_LIMIT = 1_000_000;

    /// @dev Who to call back, per Pyth sequence number, between request and reveal.
    struct Request {
        address consumer;
        address player;
    }

    mapping(uint64 => Request) private _requests;

    /// @dev A fulfillment arrived for a sequence number we never requested (or
    /// already served). Should be impossible given Pyth's guarantees.
    error UnknownSequence(uint64 sequence);

    /// @param entropyContract The Pyth Entropy V2 proxy address (SPEC §6.1).
    /// @param entropyProvider The default provider address (SPEC §6.1).
    constructor(address entropyContract, address entropyProvider) {
        entropy = IEntropyV2(entropyContract);
        provider = entropyProvider;
    }

    /// @inheritdoc IRandomSource
    function fee() external view returns (uint256) {
        return uint256(entropy.getFeeV2(provider, CALLBACK_GAS_LIMIT));
    }

    /// @inheritdoc IRandomSource
    /// @dev Forwards the whole `msg.value` as the Pyth fee (PortalLab sends
    /// exactly `fee()`), records the consumer (`msg.sender`) and the player, and
    /// returns Pyth's sequence number as the request id.
    function requestWord(address player) external payable returns (uint64 requestId) {
        requestId = entropy.requestV2{value: msg.value}(provider, CALLBACK_GAS_LIMIT);
        _requests[requestId] = Request({consumer: msg.sender, player: player});
    }

    /// @inheritdoc IEntropyConsumer
    function getEntropy() internal view override returns (address) {
        return address(entropy);
    }

    /// @dev Pyth fulfillment: deliver the word to the consumer that requested it.
    /// The outer `_entropyCallback` has already proven `msg.sender` is Entropy.
    function entropyCallback(uint64 sequence, address, /*provider*/ bytes32 randomNumber) internal override {
        Request memory r = _requests[sequence];
        if (r.consumer == address(0)) revert UnknownSequence(sequence);
        delete _requests[sequence];
        IRandomConsumer(r.consumer).receiveWord(r.player, sequence, uint256(randomNumber));
    }
}
