// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IRandomSource — pluggable source of a single random word (SPEC §6).
/// @notice The game (PortalLab) never talks to Pyth directly. It asks an
/// IRandomSource for one 256-bit word per deferred action and, separately,
/// receives that word back through the IRandomConsumer callback. Swapping the
/// randomness provider — Pyth today, anything tomorrow — is therefore a change
/// of ONE address in the PortalLab constructor, not a change to the game.
///
/// @dev The split (request now, delivery later, in a separate call) is the
/// essence of the design: real entropy (Pyth Entropy V2) is asynchronous — the
/// value is not known until a fulfillment transaction lands two blocks later —
/// and the interface must not pretend otherwise. `requestWord` therefore returns
/// only an id; the word arrives through `IRandomConsumer.receiveWord`.
interface IRandomSource {
    /// @notice The fee, in wei of the native coin, that `requestWord` requires.
    /// For Pyth Entropy V2 on Monad this is a FLAT amount (independent of the
    /// callback gas limit). The caller must forward at least this much.
    function fee() external view returns (uint256);

    /// @notice Request one random word on behalf of `player`.
    /// @dev The caller (the consumer) is recorded as `msg.sender`; the word is
    /// delivered back to that same address via `IRandomConsumer.receiveWord` in a
    /// LATER call. Reverts if `msg.value < fee()`.
    /// @param player The player the word is for; echoed back on delivery.
    /// @return requestId An id unique to this request, used to match the delivery.
    function requestWord(address player) external payable returns (uint64 requestId);
}

/// @title IRandomConsumer — receives a word delivered by an IRandomSource.
/// @notice PortalLab implements this. The source calls `receiveWord` to hand
/// back the word for a previously issued `requestId`. The consumer MUST verify
/// that `msg.sender` is its configured source and that `requestId` matches an
/// outstanding request — otherwise anyone could inject a chosen word (SPEC §6.4).
interface IRandomConsumer {
    /// @notice Deliver `word` for the request `requestId` made for `player`.
    function receiveWord(address player, uint64 requestId, uint256 word) external;
}
