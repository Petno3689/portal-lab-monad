// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Milestone 0 measurement probe. Not a game contract: it exists only to
/// measure how the Monad testnet behaves — block time, timestamp precision, and
/// whether consecutive transactions land in distinct blocks.
contract Probe {
    /// @notice Number of times `tick` has been called since deployment.
    uint256 public count;

    /// @notice Emitted on every `tick`. The block fields are the measurement:
    /// a series of these events lets us derive block time and timestamp
    /// precision from the explorer.
    event Ticked(
        uint256 indexed newCount,
        uint256 blockTimestamp,
        uint256 blockNumber,
        address sender
    );

    /// @notice Increment the counter and record the current block context.
    function tick() external {
        count += 1;
        emit Ticked(count, block.timestamp, block.number, msg.sender);
    }
}
