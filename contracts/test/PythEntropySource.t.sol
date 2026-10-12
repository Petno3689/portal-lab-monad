// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {PythEntropySource} from "../src/PythEntropySource.sol";
import {PortalLab} from "../src/PortalLab.sol";
import {IRandomSource, IRandomConsumer} from "../src/IRandomSource.sol";
import {
    Game,
    Portal,
    Pending,
    PortalType,
    PortalStatus,
    Action,
    MAX_OPEN_PORTALS
} from "../src/PortalLabTypes.sol";
import {DefaultConfig} from "./utils/DefaultConfig.sol";

// ── MockEntropy ───────────────────────────────────────────────────────────────

/// @title MockEntropy — test-only Pyth Entropy V2 stand-in.
/// @notice Issues monotonically increasing sequence numbers and delivers words
/// to a consumer via raw ABI encoding (never a typed Solidity interface) so
/// that tests prove the correct selector is exposed — not just our own typedef.
contract MockEntropy {
    uint128 public mockFee;
    uint64 private _seq;

    constructor(uint128 fee_) {
        mockFee = fee_;
    }

    function getFeeV2(address, uint32) external view returns (uint128) {
        return mockFee;
    }

    function requestV2(address, uint32) external payable returns (uint64 assignedSequenceNumber) {
        assignedSequenceNumber = ++_seq;
    }

    /// @notice Call `_entropyCallback` on `consumer` using raw ABI encoding.
    /// @dev The signature string here is the INDEPENDENT check: if the adapter's
    /// external function were named differently, this call would land on the
    /// fallback (or not at all) and `ok` would be false — `require(ok)` bubbles
    /// the inner revert so callers can assert on its selector.
    function deliver(address consumer, uint64 sequence, bytes32 randomNumber) external {
        bytes memory data = abi.encodeWithSignature(
            "_entropyCallback(uint64,address,bytes32)",
            sequence,
            address(this),
            randomNumber
        );
        (bool ok, bytes memory ret) = consumer.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

// ── MockConsumer ──────────────────────────────────────────────────────────────

/// @notice Records the last word delivered via IRandomConsumer.receiveWord.
contract MockConsumer is IRandomConsumer {
    address public lastPlayer;
    uint64 public lastRequestId;
    uint256 public lastWord;
    bool public received;

    function receiveWord(address player, uint64 requestId, uint256 word) external {
        lastPlayer = player;
        lastRequestId = requestId;
        lastWord = word;
        received = true;
    }
}

// ── PythHarness ───────────────────────────────────────────────────────────────

/// @dev Minimal PortalLab subclass that accepts a custom IRandomSource and exposes
/// state-write helpers so integration tests can plant a game without going through
/// startGame + spawns.
contract PythHarness is PortalLab {
    constructor(IRandomSource src)
        PortalLab(DefaultConfig.config(), DefaultConfig.portalTypeParams(), src)
    {}

    function setGame(address p, Game calldata g) external {
        _players[p].game = g;
    }

    function setPortal(address p, uint8 slot, Portal calldata portal) external {
        _players[p].portals[slot] = portal;
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

/// @title PythEntropySourceTest — Ticket 4.4a: callback-name fix and adapter coverage.
contract PythEntropySourceTest is Test {
    MockEntropy internal entropy;
    PythEntropySource internal adapter;
    MockConsumer internal consumer;
    address internal provider;
    address internal alice;

    uint128 internal constant FEE = 0.01 ether;
    uint40 internal constant BASE = 1_000;

    // Accept refunds from lab.act (overpay change).
    receive() external payable {}

    function setUp() public {
        provider = address(0xBEEF);
        alice = address(0xA11CE);
        entropy = new MockEntropy(FEE);
        consumer = new MockConsumer();
        adapter = new PythEntropySource(address(entropy), provider);
        vm.warp(BASE);
    }

    // ── 2.5: fee() and requestWord fee-forwarding ────────────────────────────────

    function test_Fee_ReturnsMockFee() public {
        assertEq(adapter.fee(), FEE);
    }

    function test_RequestWord_ForwardsFullFee() public {
        vm.deal(address(consumer), 1 ether);
        vm.prank(address(consumer));
        uint64 id = adapter.requestWord{value: FEE}(alice);

        assertGt(id, 0, "requestId must be non-zero");
        assertEq(address(entropy).balance, FEE, "entire fee forwarded to Entropy");
    }

    // ── 2.2: critical selector test ──────────────────────────────────────────────

    /// @notice Proves that `_entropyCallback(uint64,address,bytes32)` is the
    /// EXTERNAL function name on the deployed adapter, independent of our own
    /// typed interface. The call is made via raw abi.encodeWithSignature — if
    /// the name were wrong, `ok` would be false and the assertion would fail.
    function test_Selector_EntropyCallbackIsExternalAndCallable() public {
        // Prime a live request so the body runs without UnknownSequence.
        vm.deal(address(consumer), 1 ether);
        vm.prank(address(consumer));
        uint64 id = adapter.requestWord{value: FEE}(alice);

        // Independent selector check — this string is the test's invariant.
        bytes memory callData = abi.encodeWithSignature(
            "_entropyCallback(uint64,address,bytes32)",
            id,
            address(entropy),
            bytes32(uint256(0x1234))
        );
        vm.prank(address(entropy)); // must come from the Entropy contract
        (bool ok,) = address(adapter).call(callData);
        assertTrue(ok, "_entropyCallback(uint64,address,bytes32) must be externally callable from Entropy");
    }

    // ── 2.3: full path ───────────────────────────────────────────────────────────

    /// @notice PortalLab.act → PythEntropySource.requestWord → MockEntropy.requestV2
    /// → MockEntropy.deliver (raw selector) → PythEntropySource._entropyCallback
    /// → PythEntropySource.entropyCallback → PortalLab.receiveWord → survey applied.
    function test_FullPath_ActRequestDeliverSurveyApplied() public {
        PythHarness lab = new PythHarness(adapter);
        address p = address(this);

        {
            Game memory g;
            g.startedAt = BASE;
            g.lastTickAt = BASE;
            g.hp = 100;
            g.power = 100;
            g.observersFree = 3;
            g.rescuersFree = 2;
            g.openPortals = 1;
            lab.setGame(p, g);
        }
        {
            Portal memory portal;
            portal.status = PortalStatus.Open;
            portal.surveyed = false;
            portal.portalType = PortalType.LongLived;
            portal.snapshotAt = BASE;
            portal.hoursToCollapse = 1000;
            lab.setPortal(p, 0, portal);
        }

        // Commit: PortalLab → PythEntropySource → MockEntropy.
        vm.deal(p, 1 ether);
        lab.act{value: FEE}(0, Action.SendObserver);

        Pending memory pend = lab.getPending(p);
        assertTrue(pend.active, "survey pending after commit");
        uint64 reqId = pend.requestId;
        assertGt(reqId, 0, "requestId assigned");

        // Deliver: MockEntropy calls adapter via real selector; adapter forwards
        // to PortalLab.receiveWord; survey is applied.
        entropy.deliver(address(adapter), reqId, keccak256("pyth-word"));

        assertTrue(lab.getPortals(p)[0].surveyed, "portal surveyed after delivery");
        assertFalse(lab.getPending(p).active, "pending cleared after delivery");
    }

    // ── 2.4: negative tests ──────────────────────────────────────────────────────

    /// Any caller that is NOT the Entropy contract is rejected.
    function test_Neg_DeliveryFromNonEntropy_Reverts() public {
        vm.deal(address(consumer), 1 ether);
        vm.prank(address(consumer));
        uint64 id = adapter.requestWord{value: FEE}(alice);

        bytes memory callData = abi.encodeWithSignature(
            "_entropyCallback(uint64,address,bytes32)",
            id,
            address(entropy),
            bytes32(0)
        );
        vm.prank(address(0xDEAD)); // not the Entropy contract
        (bool ok,) = address(adapter).call(callData);
        assertFalse(ok, "delivery from non-Entropy must revert");
    }

    /// A delivery for a sequence number never requested must revert with UnknownSequence.
    function test_Neg_UnknownSequence_Reverts() public {
        uint64 unknown = 999;
        vm.expectRevert(abi.encodeWithSelector(PythEntropySource.UnknownSequence.selector, unknown));
        entropy.deliver(address(adapter), unknown, keccak256("bad"));
    }

    /// A second delivery for the same sequence must revert (slot deleted on first).
    function test_Neg_DuplicateDelivery_Reverts() public {
        vm.deal(address(consumer), 1 ether);
        vm.prank(address(consumer));
        uint64 id = adapter.requestWord{value: FEE}(alice);

        bytes32 w = keccak256("once");
        entropy.deliver(address(adapter), id, w); // first delivery: ok

        vm.expectRevert(abi.encodeWithSelector(PythEntropySource.UnknownSequence.selector, id));
        entropy.deliver(address(adapter), id, w); // second: slot cleared, revert
    }
}
