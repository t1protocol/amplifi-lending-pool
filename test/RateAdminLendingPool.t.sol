// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AmplifiLendingPool, PoolStatus} from "../src/AmplifiLendingPool.sol";
import {RateAdminLendingPool} from "../src/RateAdminLendingPool.sol";
import {MockUSDC} from "./AmplifiLendingPool.t.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract RateAdminLendingPoolTest is Test {
    RateAdminLendingPool pool;
    MockUSDC usdc;

    address owner = makeAddr("owner");
    address teeOperator = makeAddr("teeOperator");
    address rateAdmin = makeAddr("rateAdmin");
    address stranger = makeAddr("stranger");

    uint256 constant BASE_RATE = 200; // 2%
    uint256 constant KINK_UTIL = 8500; // 85%
    uint256 constant KINK_RATE = 2000; // 20%
    uint256 constant MAX_RATE = 10000; // 100%

    // New (valid) params used to prove a write went through.
    uint256 constant NEW_BASE = 300;
    uint256 constant NEW_KINK_UTIL = 8000;
    uint256 constant NEW_KINK_RATE = 3000;
    uint256 constant NEW_MAX = 20000;

    event RateAdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event RateParamsUpdated(uint256 baseRateBps, uint256 kinkUtilizationBps, uint256 kinkRateBps, uint256 maxRateBps);

    function setUp() public {
        usdc = new MockUSDC();
        pool = new RateAdminLendingPool(
            address(usdc), owner, teeOperator, BASE_RATE, KINK_UTIL, KINK_RATE, MAX_RATE, rateAdmin
        );
    }

    function _assertNewParams() internal view {
        assertEq(pool.baseRateBps(), NEW_BASE);
        assertEq(pool.kinkUtilizationBps(), NEW_KINK_UTIL);
        assertEq(pool.kinkRateBps(), NEW_KINK_RATE);
        assertEq(pool.maxRateBps(), NEW_MAX);
    }

    // ── Construction ──────────────────────────────────────────────────────

    function test_constructor_setsRateAdmin() public view {
        assertEq(pool.rateAdmin(), rateAdmin);
    }

    function test_constructor_zeroRateAdmin_allowed() public {
        RateAdminLendingPool p = new RateAdminLendingPool(
            address(usdc), owner, teeOperator, BASE_RATE, KINK_UTIL, KINK_RATE, MAX_RATE, address(0)
        );
        assertEq(p.rateAdmin(), address(0));
    }

    // ── setRateParams access ────────────────────────────────────────────────

    function test_rateAdmin_canSetRateParams() public {
        vm.prank(rateAdmin);
        pool.setRateParams(NEW_BASE, NEW_KINK_UTIL, NEW_KINK_RATE, NEW_MAX);
        _assertNewParams();
    }

    function test_owner_canStillSetRateParams() public {
        vm.prank(owner);
        pool.setRateParams(NEW_BASE, NEW_KINK_UTIL, NEW_KINK_RATE, NEW_MAX);
        _assertNewParams();
    }

    function test_stranger_cannotSetRateParams() public {
        vm.prank(stranger);
        vm.expectRevert(RateAdminLendingPool.OnlyOwnerOrRateAdmin.selector);
        pool.setRateParams(NEW_BASE, NEW_KINK_UTIL, NEW_KINK_RATE, NEW_MAX);
    }

    function test_teeOperator_cannotSetRateParams() public {
        vm.prank(teeOperator);
        vm.expectRevert(RateAdminLendingPool.OnlyOwnerOrRateAdmin.selector);
        pool.setRateParams(NEW_BASE, NEW_KINK_UTIL, NEW_KINK_RATE, NEW_MAX);
    }

    function test_setRateParams_viaRateAdmin_emitsRateParamsUpdated() public {
        vm.expectEmit(false, false, false, true, address(pool));
        emit RateParamsUpdated(NEW_BASE, NEW_KINK_UTIL, NEW_KINK_RATE, NEW_MAX);
        vm.prank(rateAdmin);
        pool.setRateParams(NEW_BASE, NEW_KINK_UTIL, NEW_KINK_RATE, NEW_MAX);
    }

    function test_setRateParams_viaRateAdmin_validates() public {
        // base > kink violates the rate-param invariant.
        vm.prank(rateAdmin);
        vm.expectRevert(AmplifiLendingPool.InvalidRateParams.selector);
        pool.setRateParams(5000, NEW_KINK_UTIL, 3000, NEW_MAX);
    }

    // ── setRateAdmin management ─────────────────────────────────────────────

    function test_setRateAdmin_byOwner_updatesAndEmits() public {
        address newAdmin = makeAddr("newAdmin");
        vm.expectEmit(true, true, false, false, address(pool));
        emit RateAdminUpdated(rateAdmin, newAdmin);
        vm.prank(owner);
        pool.setRateAdmin(newAdmin);
        assertEq(pool.rateAdmin(), newAdmin);
    }

    function test_setRateAdmin_byNonOwner_reverts() public {
        vm.prank(rateAdmin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rateAdmin));
        pool.setRateAdmin(stranger);
    }

    function test_rotatedAdmin_canSet_oldCannot() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(owner);
        pool.setRateAdmin(newAdmin);

        vm.prank(newAdmin);
        pool.setRateParams(NEW_BASE, NEW_KINK_UTIL, NEW_KINK_RATE, NEW_MAX);
        _assertNewParams();

        vm.prank(rateAdmin);
        vm.expectRevert(RateAdminLendingPool.OnlyOwnerOrRateAdmin.selector);
        pool.setRateParams(BASE_RATE, KINK_UTIL, KINK_RATE, MAX_RATE);
    }

    function test_setRateAdmin_toZero_revokes() public {
        vm.prank(owner);
        pool.setRateAdmin(address(0));
        assertEq(pool.rateAdmin(), address(0));

        // Former admin can no longer set.
        vm.prank(rateAdmin);
        vm.expectRevert(RateAdminLendingPool.OnlyOwnerOrRateAdmin.selector);
        pool.setRateParams(NEW_BASE, NEW_KINK_UTIL, NEW_KINK_RATE, NEW_MAX);

        // Owner still can.
        vm.prank(owner);
        pool.setRateParams(NEW_BASE, NEW_KINK_UTIL, NEW_KINK_RATE, NEW_MAX);
        _assertNewParams();
    }

    // ── Scope: rateAdmin has no other privileges ─────────────────────────────

    function test_rateAdmin_cannotSetTeeOperator() public {
        vm.prank(rateAdmin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rateAdmin));
        pool.setTeeOperator(stranger);
    }

    function test_rateAdmin_cannotSetPoolStatus() public {
        vm.prank(rateAdmin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rateAdmin));
        pool.setPoolStatus(PoolStatus.WindingDown);
    }

    function test_rateAdmin_cannotSetBorrowCaps() public {
        vm.prank(rateAdmin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rateAdmin));
        pool.setBorrowCaps(1, 0, 0);
    }
}
