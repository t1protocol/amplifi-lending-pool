// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {AmplifiLendingPool, PoolStatus} from "../src/AmplifiLendingPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Run with:
///   POLYGON_RPC_URL=https://... forge test --match-contract AmplifiLendingPoolForkTest -vv
///
/// Optionally pin the fork:
///   POLYGON_FORK_BLOCK=<block> POLYGON_RPC_URL=... forge test --match-contract AmplifiLendingPoolForkTest -vv
///
/// If POLYGON_RPC_URL is unset, all tests in this file skip silently so the regular suite
/// still runs cleanly.
contract AmplifiLendingPoolForkTest is Test {
    // Polygon mainnet addresses
    address constant PUSD = 0xC011a7E12a19f7B1f670d46F03B03f3342E82DFB;
    address constant EXISTING_POOL_SMALL = 0x8F71BDE7493bB2bead209A76228D40A7702724d9;
    address constant EXISTING_POOL_BIG = 0x682656ff2B2A41fAe305a35e92Cf8DB6F54B7879;
    address constant OPERATOR_FUND = 0xAA270BeAC402474A3eDF164C51CdAD9597f01707;

    // Rate model defaults. Mirror sensible production params; specific pool may override.
    uint256 constant BASE_RATE = 200;
    uint256 constant KINK_UTIL = 8500;
    uint256 constant KINK_RATE = 2000;
    uint256 constant MAX_RATE = 10000;

    AmplifiLendingPool pool;
    IERC20 pusd;
    address owner;
    address teeOperator;
    address borrowerWallet;
    address lender1;
    address lender2;

    bool forkActive;

    function setUp() public {
        string memory rpc;
        try vm.envString("POLYGON_RPC_URL") returns (string memory v) {
            rpc = v;
        } catch {
            // No RPC configured: skip every test in this contract.
            forkActive = false;
            return;
        }
        if (bytes(rpc).length == 0) {
            forkActive = false;
            return;
        }

        uint256 forkBlock = vm.envOr("POLYGON_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, forkBlock);
        }
        forkActive = true;

        pusd = IERC20(PUSD);

        owner = makeAddr("owner");
        teeOperator = OPERATOR_FUND;
        borrowerWallet = OPERATOR_FUND;
        lender1 = makeAddr("lender1");
        lender2 = makeAddr("lender2");

        pool = new AmplifiLendingPool(PUSD, owner, teeOperator, BASE_RATE, KINK_UTIL, KINK_RATE, MAX_RATE);

        deal(PUSD, lender1, 100_000 * 1e6);
        deal(PUSD, lender2, 100_000 * 1e6);
    }

    modifier onlyFork() {
        if (!forkActive) return;
        _;
    }

    // ── Sanity: deal works on pUSD ───────────────────────────────────────

    function test_fork_dealMintedPusd() public onlyFork {
        assertEq(pusd.balanceOf(lender1), 100_000 * 1e6, "deal should write pUSD balance");
    }

    // ── Lifecycle on real pUSD ──────────────────────────────────────────

    function test_fork_depositWithdraw_preservesValue() public onlyFork {
        uint256 amount = 50_000 * 1e6;
        uint256 startBalance = pusd.balanceOf(lender1);

        vm.startPrank(lender1);
        pusd.approve(address(pool), amount);
        uint256 shares = pool.deposit(amount);
        vm.stopPrank();

        assertGt(shares, 0, "shares minted");
        assertEq(pusd.balanceOf(lender1), startBalance - amount, "pUSD pulled into pool");

        vm.prank(lender1);
        pool.withdraw(shares);

        // No interest accrued (no borrows), no other lenders, so value is preserved to the wei.
        assertEq(pusd.balanceOf(lender1), startBalance, "lender balance restored exactly");
    }

    function test_fork_fullLifecycle_interestAccruesToLender() public onlyFork {
        uint256 deposit1 = 50_000 * 1e6;

        vm.startPrank(lender1);
        pusd.approve(address(pool), deposit1);
        pool.deposit(deposit1);
        vm.stopPrank();

        // TEE borrows
        uint256 borrowAmount = 30_000 * 1e6;
        uint256 fundBalanceBefore = pusd.balanceOf(borrowerWallet);

        vm.prank(teeOperator);
        pool.borrow(1, borrowAmount, borrowerWallet);

        assertEq(pusd.balanceOf(borrowerWallet), fundBalanceBefore + borrowAmount, "borrower wallet got the loan");

        // 90 days pass
        vm.warp(block.timestamp + 90 days);

        // Full repay
        uint256 debt = pool.loanDebt(1);
        assertGt(debt, borrowAmount, "interest accrued");
        deal(PUSD, borrowerWallet, debt);
        vm.prank(borrowerWallet);
        pusd.approve(address(pool), debt);

        vm.prank(teeOperator);
        pool.repay(1, type(uint256).max);

        // Lender withdraws
        uint256 lenderShares = pool.balanceOf(lender1);
        vm.prank(lender1);
        pool.withdraw(lenderShares);

        // Lender should end up with strictly more than they deposited (received interest).
        uint256 finalBalance = pusd.balanceOf(lender1);
        assertGt(finalBalance, 100_000 * 1e6, "lender earned interest");
    }

    function test_fork_partialRepay_badDebtAbsorbedByLender() public onlyFork {
        uint256 deposit1 = 50_000 * 1e6;
        vm.startPrank(lender1);
        pusd.approve(address(pool), deposit1);
        pool.deposit(deposit1);
        vm.stopPrank();

        vm.prank(teeOperator);
        pool.borrow(1, 30_000 * 1e6, borrowerWallet);

        vm.warp(block.timestamp + 365 days);

        // borrowerWallet is a real on-chain address that may already hold pUSD on the fork.
        // Reset it to exactly the borrow principal so the partial-repay path is exercised
        // deterministically — without this, pre-existing balance could cover interest
        // and the test would full-repay instead of realizing bad debt.
        deal(PUSD, borrowerWallet, 30_000 * 1e6);
        uint256 fundBalance = pusd.balanceOf(borrowerWallet);
        vm.prank(borrowerWallet);
        pusd.approve(address(pool), fundBalance);

        uint256 lenderValueBefore = pool.sharesToAssets(pool.balanceOf(lender1));

        vm.prank(teeOperator);
        pool.repay(1, fundBalance);

        uint256 lenderValueAfter = pool.sharesToAssets(pool.balanceOf(lender1));
        assertLt(lenderValueAfter, lenderValueBefore, "bad debt reduces lender share value");
    }

    // ── ERC-4626 entry points on real pUSD ──────────────────────────────

    function test_fork_4626_depositToReceiver() public onlyFork {
        uint256 amount = 10_000 * 1e6;
        vm.startPrank(lender1);
        pusd.approve(address(pool), amount);
        uint256 shares = pool.deposit(amount, lender2);
        vm.stopPrank();

        assertEq(pool.balanceOf(lender2), shares, "receiver got shares");
        assertEq(pool.balanceOf(lender1), 0, "sender got no shares");
    }

    function test_fork_4626_redeemWithAllowance() public onlyFork {
        // lender1 deposits, then approves lender2 to redeem half on their behalf
        uint256 amount = 10_000 * 1e6;
        vm.startPrank(lender1);
        pusd.approve(address(pool), amount);
        pool.deposit(amount);
        uint256 shares = pool.balanceOf(lender1);
        pool.approve(lender2, shares / 2);
        vm.stopPrank();

        vm.prank(lender2);
        uint256 assets = pool.redeem(shares / 2, lender2, lender1);

        assertGt(assets, 0);
        assertEq(pool.balanceOf(lender1), shares - shares / 2);
    }

    // ── Migration scenario ──────────────────────────────────────────────

    function test_fork_migrationFlow_preservesValueAcrossPools() public onlyFork {
        // Simulates a lender exiting an old pool and re-entering the new one.
        // We don't touch the old pool here (it's foreign code on the fork). What we
        // verify is: pUSD that lands in a lender's wallet, deposited into the NEW pool,
        // can be withdrawn back to the lender with the same value.

        uint256 walletBalance = pusd.balanceOf(lender1);

        vm.startPrank(lender1);
        pusd.approve(address(pool), walletBalance);
        pool.deposit(walletBalance);
        uint256 shares = pool.balanceOf(lender1);
        pool.withdraw(shares);
        vm.stopPrank();

        assertEq(pusd.balanceOf(lender1), walletBalance, "no value lost on round-trip");
    }

    function test_fork_existingPoolsAlive() public view onlyFork {
        // Smoke test: existing pools respond and report sane totals on the forked block.
        // We can't safely call state-changing methods on them, but reading view fns confirms
        // the addresses are deployed and the ABI matches.
        AmplifiLendingPool small = AmplifiLendingPool(EXISTING_POOL_SMALL);
        AmplifiLendingPool big = AmplifiLendingPool(EXISTING_POOL_BIG);

        // Both should have nonzero supply (else they're empty and migration is a no-op).
        uint256 smallSupply = small.totalSupply();
        uint256 bigSupply = big.totalSupply();
        console2.log("Existing small pool totalSupply:", smallSupply);
        console2.log("Existing big pool totalSupply:", bigSupply);

        // Both should hold pUSD as their underlying — query the immutable.
        assertEq(address(small.usdc()), PUSD, "small pool underlying is pUSD");
        assertEq(address(big.usdc()), PUSD, "big pool underlying is pUSD");
    }
}
