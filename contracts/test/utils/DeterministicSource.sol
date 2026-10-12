// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRandomSource, IRandomConsumer} from "../../src/IRandomSource.sol";

/// @title DeterministicSource — test-only IRandomSource with a reproducible word.
/// @notice Stands in for Pyth in tests and local runs. The word is a pure
/// function of `(player, nonce)`, so a run is reproducible, yet — because the
/// nonce advances on every request — two successive surveys by the same player
/// still get different words, exactly as real entropy would.
///
/// @dev DELIVERY IS ALWAYS A SEPARATE CALL (`reveal`), never a synchronous
/// callback inside `requestWord`. This is not a limitation but a requirement:
/// PortalLab records the `requestId` only after `requestWord` returns, and its
/// callback (`receiveWord`) must verify the delivered id against that record
/// (Ticket 4.4 §4.2.b). A callback fired from inside `requestWord` would arrive
/// before the id was stored and so could never be verified. The ticket's "two
/// modes" (word returned "immediately" vs "on explicit command") are therefore
/// the two TIMINGS of `reveal`: call it on the next line for an immediate
/// resolution, or warp time first and then call it to exercise the
/// world-changed-underneath cancellation path.
contract DeterministicSource is IRandomSource {
    uint256 private _fee;

    /// @dev Advances on every request, so successive words differ.
    uint64 private _nonce;

    /// @dev Request-id counter. Starts at 1 so that 0 is never a valid id and can
    /// serve as "no request" in callers that want a sentinel.
    uint64 private _seq;

    /// @notice The id returned by the most recent `requestWord`. Convenience for
    /// single-threaded tests that want to reveal the request they just made.
    uint64 public lastRequestId;

    struct Request {
        address consumer;
        address player;
        uint256 word;
        bool pending;
    }

    mapping(uint64 => Request) private _requests;

    error FeeTooLow(uint256 needed, uint256 sent);
    error NotPending(uint64 requestId);

    /// @param feeWei The flat fee `requestWord` requires (0 for most tests).
    constructor(uint256 feeWei) {
        _fee = feeWei;
    }

    /// @inheritdoc IRandomSource
    function fee() external view returns (uint256) {
        return _fee;
    }

    /// @notice Test aid: change the fee after construction, to exercise the
    /// underpay/overpay paths in PortalLab.act.
    function setFee(uint256 feeWei) external {
        _fee = feeWei;
    }

    /// @inheritdoc IRandomSource
    function requestWord(address player) external payable returns (uint64 requestId) {
        if (msg.value < _fee) revert FeeTooLow(_fee, msg.value);
        requestId = ++_seq;
        uint256 word = uint256(keccak256(abi.encode(player, _nonce)));
        _nonce += 1;
        _requests[requestId] = Request({consumer: msg.sender, player: player, word: word, pending: true});
        lastRequestId = requestId;
    }

    /// @notice Deliver the word for `requestId` to the consumer that requested it.
    /// Call it immediately after the commit for an atomic-feeling survey, or after
    /// a `vm.warp` to test the cancellation-on-collapse path.
    function reveal(uint64 requestId) external {
        Request storage r = _requests[requestId];
        if (!r.pending) revert NotPending(requestId);
        r.pending = false;
        IRandomConsumer(r.consumer).receiveWord(r.player, requestId, r.word);
    }

    /// @notice The word that `reveal` would deliver for `requestId` (test aid:
    /// lets a test predict the derived outcome before revealing).
    function wordOf(uint64 requestId) external view returns (uint256) {
        return _requests[requestId].word;
    }

    /// @notice Whether `requestId` is still awaiting `reveal`.
    function isPending(uint64 requestId) external view returns (bool) {
        return _requests[requestId].pending;
    }
}
