// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Game, Portal, Config, MAX_OPEN_PORTALS} from "../src/PortalLabTypes.sol";
import {PortalLabHarness} from "./utils/PortalLabHarness.sol";
import {PreviewScenarios, PREVIEW_STATE_COUNT} from "./utils/PreviewScenarios.sol";
import {VectorCodec} from "./utils/VectorCodec.sol";

/// @title PreviewMatchesSyncTest — the promise written on `preview`, tested.
/// @notice `PortalLab.preview`'s NatSpec says its result "must match what an
/// UNPAID `sync` would persist for the same moment". That is the whole contract
/// between the front end and the chain: the client draws the world from `preview`
/// between transactions, and if the two ever disagreed the screen would be a
/// polite lie. Nothing checked the claim until now.
///
/// @dev For every reachable state (`PreviewScenarios`) and every moment worth
/// projecting it to, the test takes `preview`'s three returns, then calls `sync`
/// with ZERO value at the same moment and compares what settled in storage —
/// every field of the game and of all twelve portals, never a selection.
///
/// `sync` writes, so each comparison runs inside `vm.snapshotState` /
/// `vm.revertToState`: the state is put back before the next scenario is built,
/// which also keeps the random-word stream identical to the generator's (see
/// PreviewScenarios' note on determinism).
///
/// THE THIRD RETURN. `cappedShort` has no storage counterpart of its own, so it is
/// checked through the stamp `sync` leaves. A living world that reached `nowTs`
/// stamps `lastTickAt == nowTs`; one that stopped at the pinned edge stamps the
/// edge, strictly earlier. A world that could not age at all (no game, already
/// finished, or a clock before the start) reports `cappedShort == false` by
/// definition. The one case storage cannot witness is a run that DIED inside the
/// projected window: death stamps `lastTickAt = nowTs` whether or not the
/// projection was capped. Those are counted and reported rather than asserted on
/// a derivation storage does not support.
contract PreviewMatchesSyncTest is Test {
    PreviewScenarios private drv;
    PortalLabHarness private lab;

    function setUp() public {
        drv = new PreviewScenarios();
        lab = drv.lab();
    }

    function test_PreviewMatchesUnpaidSync() external {
        Config memory c = lab.config();

        uint256 compared;
        uint256 cappedWitnessed;
        uint256 cappedUnwitnessed;
        uint256 syncRefused;

        // In order, 0 … COUNT-1, nothing requested in between: that is the
        // contract with the driver, and it is what makes these the same worlds the
        // generator recorded.
        for (uint256 i = 0; i < PREVIEW_STATE_COUNT; i++) {
            address player = drv.build(i);
            Game memory stored = lab.getGame(player);
            uint32 covered = lab.getPending(player).coveredEpochs;

            (uint40[5] memory ts,, uint256 k) = drv.moments(stored, covered, c);
            for (uint256 j = 0; j < k; j++) {
                string memory where =
                    string.concat("state ", vm.toString(i), " moment ", vm.toString(j));

                vm.warp(ts[j]);
                (Game memory pg, Portal[MAX_OPEN_PORTALS] memory pp, bool capped) = lab.preview(player);

                uint256 snap = vm.snapshotState();
                // A refusal would make the claim untestable here, not false; it is
                // counted and reported rather than papered over.
                bool synced = true;
                try lab.sync(player) {}
                catch {
                    synced = false;
                }
                if (!synced) {
                    vm.revertToState(snap);
                    syncRefused += 1;
                    continue;
                }
                Game memory sg = lab.getGame(player);
                Portal[MAX_OPEN_PORTALS] memory sp = lab.getPortals(player);
                vm.revertToState(snap);

                _assertGame(pg, sg, where);
                _assertPortals(pp, sp, where);

                if (stored.startedAt == 0 || stored.finished || ts[j] < stored.startedAt) {
                    assertFalse(capped, string.concat("a world that cannot age reported capped at ", where));
                    cappedWitnessed += 1;
                } else if (!sg.finished) {
                    assertEq(
                        capped,
                        sg.lastTickAt < ts[j],
                        string.concat("cappedShort disagrees with the stamp sync left at ", where)
                    );
                    cappedWitnessed += 1;
                } else {
                    cappedUnwitnessed += 1;
                }

                compared += 1;
            }
        }

        console.log("states driven:", PREVIEW_STATE_COUNT);
        console.log("state/moment pairs compared:", compared);
        console.log("cappedShort witnessed by the stamp sync left:", cappedWitnessed);
        console.log("cappedShort not witnessable (the run died in the window):", cappedUnwitnessed);
        console.log("pairs skipped because sync refused:", syncRefused);

        // Guard against a silently empty run: eleven states, three to five moments
        // each. A regression that stopped producing states would otherwise look
        // like a green test.
        assertGe(compared, 40, "too few state/moment pairs compared");
        assertGt(cappedWitnessed, 0, "cappedShort was never checked against storage");
    }

    /// @dev Every field, via the JSON encoder so a failure names the one that drifted.
    function _assertGame(Game memory got, Game memory want, string memory where) private pure {
        if (keccak256(abi.encode(got)) == keccak256(abi.encode(want))) return;
        assertEq(
            VectorCodec.gameJson(got),
            VectorCodec.gameJson(want),
            string.concat("preview and sync disagree about the game at ", where)
        );
    }

    function _assertPortals(
        Portal[MAX_OPEN_PORTALS] memory got,
        Portal[MAX_OPEN_PORTALS] memory want,
        string memory where
    ) private pure {
        for (uint256 s = 0; s < MAX_OPEN_PORTALS; s++) {
            if (keccak256(abi.encode(got[s])) == keccak256(abi.encode(want[s]))) continue;
            assertEq(
                VectorCodec.portalJson(got[s]),
                VectorCodec.portalJson(want[s]),
                string.concat("preview and sync disagree about a portal at ", where, " slot=", vm.toString(s))
            );
        }
    }
}
