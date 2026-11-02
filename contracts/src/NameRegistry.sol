// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title NameRegistry
/// @notice Unique, case-insensitive nicknames for leaderboard addresses.
/// @dev Rules are fixed at deploy. A name is 3..20 bytes of [A-Za-z0-9_-];
/// uniqueness is checked on the ASCII-lowercased name, display keeps the
/// case as entered. The caller (the player's game key) owns its name.
contract NameRegistry {
    uint256 public constant MIN_LENGTH = 3;
    uint256 public constant MAX_LENGTH = 20;

    error InvalidName();
    error NameTaken();
    error NoName();

    event NameSet(address indexed holder, string name);
    event NameCleared(address indexed holder);

    mapping(address => string) private _nameOf;
    mapping(bytes32 => address) private _holderOf;

    /// @notice Claim `name`, or re-case / replace the caller's current name.
    function setName(string calldata name) external {
        if (!_isValid(bytes(name))) revert InvalidName();

        bytes32 k = _key(bytes(name));
        address h = _holderOf[k];
        if (h != address(0) && h != msg.sender) revert NameTaken();

        string storage current = _nameOf[msg.sender];
        if (bytes(current).length != 0) {
            bytes32 oldKey = _key(bytes(current));
            if (oldKey != k) delete _holderOf[oldKey];
        }

        _holderOf[k] = msg.sender;
        _nameOf[msg.sender] = name;
        emit NameSet(msg.sender, name);
    }

    /// @notice Release the caller's name.
    function clearName() external {
        string storage current = _nameOf[msg.sender];
        if (bytes(current).length == 0) revert NoName();

        delete _holderOf[_key(bytes(current))];
        delete _nameOf[msg.sender];
        emit NameCleared(msg.sender);
    }

    /// @notice Name held by `player`, or "" if none.
    function nameOf(address player) external view returns (string memory) {
        return _nameOf[player];
    }

    /// @notice Holder of `name` (any letter case), or address(0) if free or invalid.
    function holderOf(string calldata name) external view returns (address) {
        if (!_isValid(bytes(name))) return address(0);
        return _holderOf[_key(bytes(name))];
    }

    /// @notice Names for `players` in the same order, "" for none.
    function namesOf(address[] calldata players) external view returns (string[] memory names) {
        names = new string[](players.length);
        for (uint256 i = 0; i < players.length; i++) {
            names[i] = _nameOf[players[i]];
        }
    }

    function _isValid(bytes memory b) private pure returns (bool) {
        uint256 len = b.length;
        if (len < MIN_LENGTH || len > MAX_LENGTH) return false;
        for (uint256 i = 0; i < len; i++) {
            bytes1 c = b[i];
            bool ok = (c >= 0x30 && c <= 0x39) // 0-9
                || (c >= 0x41 && c <= 0x5A) // A-Z
                || (c >= 0x61 && c <= 0x7A) // a-z
                || c == 0x5F // _
                || c == 0x2D; // -
            if (!ok) return false;
        }
        return true;
    }

    function _key(bytes memory b) private pure returns (bytes32) {
        bytes memory lower = new bytes(b.length);
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            lower[i] = (c >= 0x41 && c <= 0x5A) ? bytes1(uint8(c) + 32) : c;
        }
        return keccak256(lower);
    }
}
