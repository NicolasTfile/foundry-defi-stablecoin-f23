// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";

contract DecentralizedStableCoinTest is Test {
    DecentralizedStableCoin public dsc;

    address public owner;
    address public user1;
    address public user2;

    uint256 public constant STARTING_AMOUNT = 100 ether;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        vm.prank(owner);
        dsc = new DecentralizedStableCoin();
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////

    function testConstructorSetsCorrectName() public view {
        assertEq(dsc.name(), "DecentralizedStableCoin");
    }

    function testConstructorSetsCorrectSymbol() public view {
        assertEq(dsc.symbol(), "DSC");
    }

    function testConstructorSetsCorrectOwner() public view {
        assertEq(dsc.owner(), owner);
    }

    function testConstructorStartsWithZeroSupply() public view {
        assertEq(dsc.totalSupply(), 0);
    }

    ////////////////
    // Mint Tests //
    ////////////////

    function testMintRevertsIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        dsc.mint(user1, STARTING_AMOUNT);
    }

    function testMintRevertsIfToAddressIsZero() public {
        vm.prank(owner);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__NotZeroAddress.selector);
        dsc.mint(address(0), STARTING_AMOUNT);
    }

    function testMintRevertsIfAmountIsZero() public {
        vm.prank(owner);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
        dsc.mint(user1, 0);
    }

    function testMintSucceedsWithValidParameters() public {
        vm.prank(owner);
        bool success = dsc.mint(user1, STARTING_AMOUNT);

        assertTrue(success);
        assertEq(dsc.balanceOf(user1), STARTING_AMOUNT);
        assertEq(dsc.totalSupply(), STARTING_AMOUNT);
    }

    function testMintEmitsTransferEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), user1, STARTING_AMOUNT);
        dsc.mint(user1, STARTING_AMOUNT);
    }

    function testMintMultipleTimes() public {
        vm.startPrank(owner);
        dsc.mint(user1, STARTING_AMOUNT);
        dsc.mint(user1, STARTING_AMOUNT);
        vm.stopPrank();

        assertEq(dsc.balanceOf(user1), STARTING_AMOUNT * 2);
        assertEq(dsc.totalSupply(), STARTING_AMOUNT * 2);
    }

    function testMintToMultipleUsers() public {
        vm.startPrank(owner);
        dsc.mint(user1, STARTING_AMOUNT);
        dsc.mint(user2, STARTING_AMOUNT);
        vm.stopPrank();

        assertEq(dsc.balanceOf(user1), STARTING_AMOUNT);
        assertEq(dsc.balanceOf(user2), STARTING_AMOUNT);
        assertEq(dsc.totalSupply(), STARTING_AMOUNT * 2);
    }

    function testFuzzMint(address to, uint256 amount) public {
        vm.assume(to != address(0));
        vm.assume(amount > 0 && amount < type(uint256).max);

        vm.prank(owner);
        bool success = dsc.mint(to, amount);

        assertTrue(success);
        assertEq(dsc.balanceOf(to), amount);
    }

    ////////////////
    // Burn Tests //
    ////////////////

    function testBurnRevertsIfNotOwner() public {
        vm.prank(owner);
        dsc.mint(user1, STARTING_AMOUNT);

        vm.prank(user1);
        vm.expectRevert();
        dsc.burn(STARTING_AMOUNT);
    }

    function testBurnRevertsIfAmountIsZero() public {
        vm.prank(owner);
        dsc.mint(owner, STARTING_AMOUNT);

        vm.prank(owner);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
        dsc.burn(0);
    }

    function testBurnRevertsIfAmountExceedsBalance() public {
        vm.prank(owner);
        dsc.mint(owner, STARTING_AMOUNT);

        vm.prank(owner);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__BurnAmountExceedsBalance.selector);
        dsc.burn(STARTING_AMOUNT + 1);
    }

    function testBurnSucceedsWithValidParameters() public {
        vm.startPrank(owner);
        dsc.mint(owner, STARTING_AMOUNT);
        dsc.burn(STARTING_AMOUNT);
        vm.stopPrank();

        assertEq(dsc.balanceOf(owner), 0);
        assertEq(dsc.totalSupply(), 0);
    }

    function testBurnEmitsTransferEvent() public {
        vm.startPrank(owner);
        dsc.mint(owner, STARTING_AMOUNT);

        vm.expectEmit(true, true, false, true);
        emit Transfer(owner, address(0), STARTING_AMOUNT);
        dsc.burn(STARTING_AMOUNT);
        vm.stopPrank();
    }

    function testBurnPartialAmount() public {
        vm.startPrank(owner);
        dsc.mint(owner, STARTING_AMOUNT);
        dsc.burn(STARTING_AMOUNT / 2);
        vm.stopPrank();

        assertEq(dsc.balanceOf(owner), STARTING_AMOUNT / 2);
        assertEq(dsc.totalSupply(), STARTING_AMOUNT / 2);
    }

    function testBurnMultipleTimes() public {
        vm.startPrank(owner);
        dsc.mint(owner, STARTING_AMOUNT);
        dsc.burn(STARTING_AMOUNT / 4);
        dsc.burn(STARTING_AMOUNT / 4);
        vm.stopPrank();

        assertEq(dsc.balanceOf(owner), STARTING_AMOUNT / 2);
        assertEq(dsc.totalSupply(), STARTING_AMOUNT / 2);
    }

    function testFuzzBurn(uint256 mintAmount, uint256 burnAmount) public {
        vm.assume(mintAmount > 0 && mintAmount < type(uint256).max / 2);
        vm.assume(burnAmount > 0 && burnAmount <= mintAmount);

        vm.startPrank(owner);
        dsc.mint(owner, mintAmount);
        dsc.burn(burnAmount);
        vm.stopPrank();

        assertEq(dsc.balanceOf(owner), mintAmount - burnAmount);
        assertEq(dsc.totalSupply(), mintAmount - burnAmount);
    }

    ////////////////////
    // Transfer Tests //
    ////////////////////

    function testTransferWorks() public {
        vm.prank(owner);
        dsc.mint(user1, STARTING_AMOUNT);

        vm.prank(user1);
        bool success = dsc.transfer(user2, STARTING_AMOUNT / 2);

        assertTrue(success);
        assertEq(dsc.balanceOf(user1), STARTING_AMOUNT / 2);
        assertEq(dsc.balanceOf(user2), STARTING_AMOUNT / 2);
    }

    function testTransferFromWorks() public {
        vm.prank(owner);
        dsc.mint(user1, STARTING_AMOUNT);

        vm.prank(user1);
        dsc.approve(user2, STARTING_AMOUNT);

        vm.prank(user2);
        bool success = dsc.transferFrom(user1, user2, STARTING_AMOUNT / 2);

        assertTrue(success);
        assertEq(dsc.balanceOf(user1), STARTING_AMOUNT / 2);
        assertEq(dsc.balanceOf(user2), STARTING_AMOUNT / 2);
    }

    /////////////////////
    // Ownership Tests //
    /////////////////////

    function testOwnershipCanBeTransferred() public {
        vm.prank(owner);
        dsc.transferOwnership(user1);

        assertEq(dsc.owner(), user1);
    }

    function testNewOwnerCanMint() public {
        vm.prank(owner);
        dsc.transferOwnership(user1);

        vm.prank(user1);
        bool success = dsc.mint(user2, STARTING_AMOUNT);

        assertTrue(success);
        assertEq(dsc.balanceOf(user2), STARTING_AMOUNT);
    }

    function testOldOwnerCannotMintAfterTransfer() public {
        vm.prank(owner);
        dsc.transferOwnership(user1);

        vm.prank(owner);
        vm.expectRevert();
        dsc.mint(user2, STARTING_AMOUNT);
    }

    ////////////////////////
    // Integration Tests  //
    ////////////////////////

    function testMintAndBurnCycle() public {
        vm.startPrank(owner);
        dsc.mint(owner, STARTING_AMOUNT);
        assertEq(dsc.totalSupply(), STARTING_AMOUNT);

        dsc.burn(STARTING_AMOUNT);
        assertEq(dsc.totalSupply(), 0);
        vm.stopPrank();
    }

    function testComplexScenario() public {
        vm.startPrank(owner);
        // Mint to multiple users
        dsc.mint(user1, STARTING_AMOUNT);
        dsc.mint(user2, STARTING_AMOUNT);
        dsc.mint(owner, STARTING_AMOUNT);
        vm.stopPrank();

        assertEq(dsc.totalSupply(), STARTING_AMOUNT * 3);

        // User1 transfers to user2
        vm.prank(user1);
        bool success = dsc.transfer(user2, STARTING_AMOUNT / 2);

        assertTrue(success);
        assertEq(dsc.balanceOf(user1), STARTING_AMOUNT / 2);
        assertEq(dsc.balanceOf(user2), STARTING_AMOUNT + STARTING_AMOUNT / 2);

        // Owner burns some tokens
        vm.prank(owner);
        dsc.burn(STARTING_AMOUNT / 2);

        assertEq(dsc.totalSupply(), STARTING_AMOUNT * 3 - STARTING_AMOUNT / 2);
    }
}
