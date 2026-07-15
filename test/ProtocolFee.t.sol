// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AmplifiLendingPool, PoolStatus} from "../src/AmplifiLendingPool.sol";
import {MockUSDC} from "./AmplifiLendingPool.t.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ProtocolFeeTest is Test {
    AmplifiLendingPool pool;
    MockUSDC usdc;

    address owner = makeAddr("owner");
    address teeOperator = makeAddr("teeOperator");
    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    address treasury = makeAddr("treasury");
    address stranger = makeAddr("stranger");

    uint256 constant BASE_RATE = 200;
    uint256 constant KINK_UTIL = 8500;
    uint256 constant KINK_RATE = 2000;
    uint256 constant MAX_RATE = 10000;

    uint256 constant FEE_BPS = 1000; // 10%

    event ProtocolFeeUpdated(uint256 feeBps);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event ProtocolFeeAccrued(uint256 indexed loanId, uint256 interest, uint256 fee);
    event ProtocolFeesCollected(address indexed to, uint256 amount);

    function setUp() public {
        usdc = new MockUSDC();
        pool = new AmplifiLendingPool(address(usdc), owner, teeOperator, BASE_RATE, KINK_UTIL, KINK_RATE, MAX_RATE);
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    function _deposit(uint256 amount) internal {
        usdc.mint(lender, amount);
        vm.startPrank(lender);
        usdc.approve(address(pool), amount);
        pool.deposit(amount);
        vm.stopPrank();
    }

    function _borrow(uint256 loanId, uint256 amount) internal {
        vm.prank(teeOperator);
        pool.borrow(loanId, amount, borrower);
    }

    /// @dev Full push-based repay of the current debt (after accrual). Returns the interest paid.
    function _repayFull(uint256 loanId) internal returns (uint256 principal, uint256 interest, uint256 debt) {
        pool.accrueInterest();
        principal = pool.loanPrincipal(loanId);
        debt = pool.loanDebt(loanId);
        interest = debt > principal ? debt - principal : 0;
        uint256 bal = usdc.balanceOf(borrower);
        if (bal < debt) usdc.mint(borrower, debt - bal);
        vm.startPrank(borrower);
        usdc.transfer(address(pool), debt);
        pool.repay(loanId, debt);
        vm.stopPrank();
    }

    function _setFee(uint256 bps) internal {
        vm.prank(owner);
        pool.setProtocolFee(bps);
    }

    // ── Default off / behavior-neutral ───────────────────────────────────────

    function test_defaultFeeBps_isZero() public view {
        assertEq(pool.feeBps(), 0);
        assertEq(pool.protocolFeesAccrued(), 0);
    }

    function test_noFeeSet_lendersGetAllInterest() public {
        _deposit(1_000e6);
        _borrow(1, 500e6);
        vm.warp(block.timestamp + 365 days);
        (, uint256 interest,) = _repayFull(1);
        assertGt(interest, 0);
        assertEq(pool.protocolFeesAccrued(), 0);
        // All interest is lender value: totalAssets == idle balance, nothing reserved.
        assertEq(pool.totalAssets(), usdc.balanceOf(address(pool)));
    }

    // ── setProtocolFee ────────────────────────────────────────────────────────

    function test_setProtocolFee_ownerUpdatesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(pool));
        emit ProtocolFeeUpdated(FEE_BPS);
        vm.prank(owner);
        pool.setProtocolFee(FEE_BPS);
        assertEq(pool.feeBps(), FEE_BPS);
    }

    function test_setProtocolFee_nonOwnerReverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        pool.setProtocolFee(FEE_BPS);
    }

    function test_setProtocolFee_aboveCapReverts() public {
        vm.prank(owner);
        vm.expectRevert(AmplifiLendingPool.InvalidFeeParams.selector);
        pool.setProtocolFee(5001);
    }

    function test_setProtocolFee_atCapOk() public {
        vm.prank(owner);
        pool.setProtocolFee(5000);
        assertEq(pool.feeBps(), 5000);
    }

    // ── Fee taken on full repay ────────────────────────────────────────────────

    function test_fee_takenOnFullRepay() public {
        _setFee(FEE_BPS);
        _deposit(1_000e6);
        _borrow(1, 500e6);
        vm.warp(block.timestamp + 365 days);

        (, uint256 interest,) = _repayFull(1);
        uint256 expectedFee = (interest * FEE_BPS) / 10_000;

        assertGt(expectedFee, 0);
        assertEq(pool.protocolFeesAccrued(), expectedFee);
    }

    function test_fee_reservedOutOfLenderAssets() public {
        _setFee(FEE_BPS);
        _deposit(1_000e6);
        _borrow(1, 500e6);
        vm.warp(block.timestamp + 365 days);
        _repayFull(1);

        uint256 fee = pool.protocolFeesAccrued();
        assertGt(fee, 0);
        // Idle USDC minus the reserved fee is what lenders can touch.
        assertEq(pool.totalAssets(), usdc.balanceOf(address(pool)) - fee);
        assertEq(pool.availableLiquidity(), usdc.balanceOf(address(pool)) - fee);
    }

    function test_feeAccrued_event() public {
        _setFee(FEE_BPS);
        _deposit(1_000e6);
        _borrow(1, 500e6);
        vm.warp(block.timestamp + 365 days);

        pool.accrueInterest();
        uint256 debt = pool.loanDebt(1);
        uint256 interest = debt - 500e6;
        uint256 fee = (interest * FEE_BPS) / 10_000;

        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.transfer(address(pool), debt);
        vm.expectEmit(true, false, false, true, address(pool));
        emit ProtocolFeeAccrued(1, interest, fee);
        pool.repay(1, debt);
        vm.stopPrank();
    }

    // ── No fee on bad debt / zero interest ─────────────────────────────────────

    function test_noFee_onBadDebt() public {
        _setFee(FEE_BPS);
        _deposit(1_000e6);
        _borrow(1, 500e6);
        vm.warp(block.timestamp + 365 days);

        pool.accrueInterest();
        uint256 debt = pool.loanDebt(1);
        uint256 short = debt - 1; // 1 wei short => bad debt

        usdc.mint(borrower, short);
        vm.startPrank(borrower);
        usdc.transfer(address(pool), short);
        pool.repay(1, short);
        vm.stopPrank();

        assertEq(pool.protocolFeesAccrued(), 0);
        assertEq(pool.totalBadDebtRealized(), 1);
    }

    function test_noFee_onZeroInterest() public {
        _setFee(FEE_BPS);
        _deposit(1_000e6);
        _borrow(1, 500e6);
        // Repay in the same block: no interest accrued.
        (, uint256 interest,) = _repayFull(1);
        assertEq(interest, 0);
        assertEq(pool.protocolFeesAccrued(), 0);
    }

    // ── Reserve protected from lender withdrawals ──────────────────────────────

    function test_reserveSurvivesLenderMaxWithdraw() public {
        _setFee(FEE_BPS);
        _deposit(1_000e6);
        _borrow(1, 500e6);
        vm.warp(block.timestamp + 365 days);
        _repayFull(1);

        uint256 fee = pool.protocolFeesAccrued();
        assertGt(fee, 0);

        // Lender pulls everything available; the reserved fee must remain in the pool.
        uint256 shares = pool.balanceOf(lender);
        vm.prank(lender);
        pool.withdraw(shares);

        assertGe(usdc.balanceOf(address(pool)), fee);
        assertEq(pool.protocolFeesAccrued(), fee);
    }

    // ── setFeeRecipient ─────────────────────────────────────────────────────────

    function test_setFeeRecipient_ownerUpdatesAndEmits() public {
        vm.expectEmit(true, true, false, false, address(pool));
        emit FeeRecipientUpdated(address(0), treasury);
        vm.prank(owner);
        pool.setFeeRecipient(treasury);
        assertEq(pool.feeRecipient(), treasury);
    }

    function test_setFeeRecipient_nonOwnerReverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        pool.setFeeRecipient(treasury);
    }

    // ── collectProtocolFees ─────────────────────────────────────────────────────

    function _accrueSomeFee() internal returns (uint256 fee) {
        _setFee(FEE_BPS);
        _deposit(1_000e6);
        _borrow(1, 500e6);
        vm.warp(block.timestamp + 365 days);
        _repayFull(1);
        fee = pool.protocolFeesAccrued();
        assertGt(fee, 0);
    }

    function test_collect_byOwner() public {
        uint256 fee = _accrueSomeFee();
        vm.prank(owner);
        pool.collectProtocolFees(treasury, fee);
        assertEq(usdc.balanceOf(treasury), fee);
        assertEq(pool.protocolFeesAccrued(), 0);
    }

    function test_collect_byFeeRecipient() public {
        uint256 fee = _accrueSomeFee();
        vm.prank(owner);
        pool.setFeeRecipient(treasury);
        vm.prank(treasury);
        pool.collectProtocolFees(treasury, fee);
        assertEq(usdc.balanceOf(treasury), fee);
        assertEq(pool.protocolFeesAccrued(), 0);
    }

    function test_collect_unauthorizedReverts() public {
        _accrueSomeFee();
        vm.prank(stranger);
        vm.expectRevert(AmplifiLendingPool.OnlyOwnerOrFeeRecipient.selector);
        pool.collectProtocolFees(stranger, 1);
    }

    function test_collect_exceedsAccruedReverts() public {
        uint256 fee = _accrueSomeFee();
        vm.prank(owner);
        vm.expectRevert(AmplifiLendingPool.FeeExceedsAccrued.selector);
        pool.collectProtocolFees(treasury, fee + 1);
    }

    function test_collect_partial() public {
        uint256 fee = _accrueSomeFee();
        vm.prank(owner);
        pool.collectProtocolFees(treasury, fee / 2);
        assertEq(usdc.balanceOf(treasury), fee / 2);
        assertEq(pool.protocolFeesAccrued(), fee - fee / 2);
    }
}
