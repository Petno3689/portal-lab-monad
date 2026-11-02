// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {NameRegistry} from "../src/NameRegistry.sol";

contract NameRegistryTest is Test {
    event NameSet(address indexed holder, string name);
    event NameCleared(address indexed holder);

    NameRegistry internal reg;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        reg = new NameRegistry();
    }

    function _set(address who, string memory name) internal {
        vm.prank(who);
        reg.setName(name);
    }

    function _expectSetRevert(address who, string memory name, bytes4 sel) internal {
        vm.prank(who);
        vm.expectRevert(sel);
        reg.setName(name);
    }

    function test_validSetAndEvent() public {
        vm.expectEmit(true, false, false, true);
        emit NameSet(alice, "Petno_1");
        _set(alice, "Petno_1");
        assertEq(reg.nameOf(alice), "Petno_1");
        assertEq(reg.holderOf("Petno_1"), alice);
    }

    function test_lengthBounds() public {
        _expectSetRevert(alice, "ab", NameRegistry.InvalidName.selector);
        _expectSetRevert(alice, "abcdefghijklmnopqrstu", NameRegistry.InvalidName.selector); // 21
        _set(alice, "abc");
        _set(bob, "abcdefghijklmnopqrst"); // 20
        assertEq(reg.nameOf(bob), "abcdefghijklmnopqrst");
    }

    function test_invalidCharacters() public {
        _expectSetRevert(alice, "", NameRegistry.InvalidName.selector);
        _expectSetRevert(alice, "ab cd", NameRegistry.InvalidName.selector);
        _expectSetRevert(alice, "ab.cd", NameRegistry.InvalidName.selector);
        _expectSetRevert(alice, "ab@cd", NameRegistry.InvalidName.selector);
        _expectSetRevert(alice, unicode"Петя", NameRegistry.InvalidName.selector);
        _expectSetRevert(alice, unicode"ab🔥cd", NameRegistry.InvalidName.selector);
    }

    function test_uppercaseReturnedAsEntered() public {
        _set(alice, "PETNO");
        assertEq(reg.nameOf(alice), "PETNO");
    }

    function test_takenCaseInsensitive() public {
        _set(alice, "petno");
        _expectSetRevert(bob, "Petno", NameRegistry.NameTaken.selector);
    }

    function test_holderRecases() public {
        _set(alice, "petno");
        vm.expectEmit(true, false, false, true);
        emit NameSet(alice, "PeTnO");
        _set(alice, "PeTnO");
        assertEq(reg.nameOf(alice), "PeTnO");
        assertEq(reg.holderOf("petno"), alice);
        _expectSetRevert(bob, "petno", NameRegistry.NameTaken.selector);
    }

    function test_renameFreesOld() public {
        _set(alice, "first");
        _set(alice, "second");
        assertEq(reg.holderOf("first"), address(0));
        assertEq(reg.holderOf("second"), alice);
        _set(bob, "FIRST");
        assertEq(reg.nameOf(bob), "FIRST");
    }

    function test_clearFrees() public {
        _set(alice, "gone");
        vm.expectEmit(true, false, false, false);
        emit NameCleared(alice);
        vm.prank(alice);
        reg.clearName();
        assertEq(reg.nameOf(alice), "");
        assertEq(reg.holderOf("gone"), address(0));
        _set(bob, "Gone");
        assertEq(reg.holderOf("gone"), bob);
    }

    function test_clearWithoutNameReverts() public {
        vm.prank(alice);
        vm.expectRevert(NameRegistry.NoName.selector);
        reg.clearName();
    }

    function test_views() public {
        _set(alice, "Alice");
        _set(bob, "Bob");
        assertEq(reg.nameOf(address(0xDEAD)), "");
        assertEq(reg.holderOf("free_name"), address(0));
        assertEq(reg.holderOf("bad name!"), address(0));
        assertEq(reg.holderOf("ALICE"), alice);

        address[] memory list = new address[](3);
        list[0] = bob;
        list[1] = address(0xDEAD);
        list[2] = alice;
        string[] memory names = reg.namesOf(list);
        assertEq(names.length, 3);
        assertEq(names[0], "Bob");
        assertEq(names[1], "");
        assertEq(names[2], "Alice");
    }

    function testFuzz_otherAddressCannotTakeName(address a, address b, uint256 seed) public {
        // address(0) cannot send transactions and means "free" in the registry.
        vm.assume(a != b && a != address(0) && b != address(0));
        string memory name = "FuzzName_7";
        _set(a, name);

        bytes memory raw = bytes(name);
        bytes memory variant = new bytes(raw.length);
        for (uint256 i = 0; i < raw.length; i++) {
            bytes1 c = raw[i];
            bool isLetter = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
            if (isLetter && ((seed >> i) & 1) == 1) {
                // flip case
                c = bytes1(uint8(c) ^ 0x20);
            }
            variant[i] = c;
        }
        _expectSetRevert(b, string(variant), NameRegistry.NameTaken.selector);
    }
}
