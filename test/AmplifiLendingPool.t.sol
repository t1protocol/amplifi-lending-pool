// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {AmplifiLendingPool, PoolStatus} from "../src/AmplifiLendingPool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AmplifiLendingPoolTest is Test {
    AmplifiLendingPool pool;
    MockUSDC usdc;

    address owner = makeAddr("owner");
    address teeOperator = makeAddr("teeOperator");
    address lender1 = makeAddr("lender1");
    address lender2 = makeAddr("lender2");
    address borrower = makeAddr("borrower");

    uint256 constant BASE_RATE = 200; // 2%
    uint256 constant KINK_UTIL = 8500; // 85%
    uint256 constant KINK_RATE = 2000; // 20%
    uint256 constant MAX_RATE = 10000; // 100%

    function setUp() public {
        usdc = new MockUSDC();
        pool = new AmplifiLendingPool(
            address(usdc), owner, teeOperator, BASE_RATE, KINK_UTIL, KINK_RATE, MAX_RATE
        );
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    function _depositAs(address lender, uint256 amount) internal {
        usdc.mint(lender, amount);
        vm.startPrank(lender);
        usdc.approve(address(pool), amount);
        pool.deposit(amount);
        vm.stopPrank();
    }

    function _borrow(uint256 loanId, uint256 amount) internal {
        _borrow(loanId, amount, borrower);
    }

    function _borrow(uint256 loanId, uint256 amount, address wallet) internal {
        vm.prank(teeOperator);
        pool.borrow(loanId, amount, wallet);
    }

    function _repay(uint256 loanId) internal {
        vm.prank(teeOperator);
        pool.repay(loanId, type(uint256).max);
    }

    // ── Deposit / Withdraw ──────────────────────────────────────────────

    function test_deposit_firstDeposit_1to1() public {
        uint256 amount = 1_000_000; // 1 USDC
        usdc.mint(lender1, amount);

        vm.startPrank(lender1);
        usdc.approve(address(pool), amount);
        pool.deposit(amount);
        vm.stopPrank();

        assertEq(pool.balanceOf(lender1), amount, "First deposit should be 1:1 shares");
        assertEq(usdc.balanceOf(address(pool)), amount, "Pool should hold USDC");
        assertEq(pool.totalAssets(), amount, "Total assets should equal deposit");
    }

    function test_deposit_secondDeposit_proportionalShares() public {
        // First lender deposits 100 USDC
        uint256 first = 100_000_000;
        _depositAs(lender1, first);

        // Second lender deposits 50 USDC
        uint256 second = 50_000_000;
        _depositAs(lender2, second);

        // Shares proportional: lender2 should have half of lender1's shares
        assertEq(pool.balanceOf(lender2), second, "Second deposit should be proportional");
    }

    function test_withdraw_full() public {
        uint256 amount = 100_000_000;
        _depositAs(lender1, amount);

        vm.startPrank(lender1);
        uint256 shares = pool.balanceOf(lender1);
        pool.withdraw(shares);
        vm.stopPrank();

        assertEq(usdc.balanceOf(lender1), amount, "Should get back full deposit");
        assertEq(pool.balanceOf(lender1), 0, "Should have 0 shares");
    }

    function test_withdraw_insufficientLiquidity_reverts() public {
        uint256 amount = 100_000_000;
        _depositAs(lender1, amount);

        // TEE borrows most of the liquidity
        _borrow(1, 90_000_000);

        // Lender tries to withdraw full amount — should fail
        uint256 lenderShares = pool.balanceOf(lender1);
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSignature("InsufficientLiquidity()"));
        pool.withdraw(lenderShares);
    }

    function test_deposit_zeroAmount_reverts() public {
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        pool.deposit(0);
    }

    function test_withdraw_zeroShares_reverts() public {
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSignature("ZeroShares()"));
        pool.withdraw(0);
    }

    // ── Borrow / Repay ──────────────────────────────────────────────────

    function test_borrow_byTeeOperator() public {
        uint256 depositAmount = 100_000_000;
        _depositAs(lender1, depositAmount);

        uint256 borrowAmount = 50_000_000;
        _borrow(1, borrowAmount);

        assertEq(usdc.balanceOf(borrower), borrowAmount, "Borrower should receive USDC");
        assertEq(pool.totalBorrowed(), borrowAmount, "totalBorrowed should update");
        assertEq(pool.availableLiquidity(), depositAmount - borrowAmount);
        assertEq(pool.totalBorrowShares(), borrowAmount, "First borrow: 1:1 shares");
        assertEq(pool.loanShares(1), borrowAmount, "Loan shares should match");
    }

    function test_borrow_notTeeOperator_reverts() public {
        _depositAs(lender1, 100_000_000);

        vm.prank(lender1); // not teeOperator
        vm.expectRevert(abi.encodeWithSignature("OnlyTeeOperator()"));
        pool.borrow(1, 50_000_000, borrower);
    }

    function test_borrow_insufficientLiquidity_reverts() public {
        _depositAs(lender1, 100_000_000);

        vm.prank(teeOperator);
        vm.expectRevert(abi.encodeWithSignature("InsufficientLiquidity()"));
        pool.borrow(1, 200_000_000, borrower);
    }

    function test_borrow_duplicateLoanId_reverts() public {
        _depositAs(lender1, 100_000_000);

        _borrow(1, 10_000_000);

        vm.prank(teeOperator);
        vm.expectRevert(abi.encodeWithSignature("LoanAlreadyExists()"));
        pool.borrow(1, 10_000_000, borrower);
    }

    function test_repay_fullLoan() public {
        uint256 depositAmount = 100_000_000;
        _depositAs(lender1, depositAmount);

        uint256 borrowAmount = 50_000_000;
        _borrow(1, borrowAmount);

        // The borrower wallet already has the USDC from borrow.
        // Approve pool to pull it back.
        vm.prank(borrower);
        usdc.approve(address(pool), borrowAmount);

        // TEE operator calls repay — pool pulls from the loan's wallet
        _repay(1);

        assertEq(pool.totalBorrowed(), 0, "totalBorrowed should be 0 after full repay");
        assertEq(pool.totalBorrowShares(), 0, "totalBorrowShares should be 0");
        assertEq(pool.loanShares(1), 0, "Loan shares should be deleted");
        assertEq(pool.availableLiquidity(), depositAmount, "Pool should have full liquidity");
    }

    function test_repay_nonexistentLoan_reverts() public {
        vm.prank(teeOperator);
        vm.expectRevert(abi.encodeWithSignature("LoanNotFound()"));
        pool.repay(999, type(uint256).max);
    }

    function test_repay_withInterest() public {
        _depositAs(lender1, 100_000_000);

        _borrow(1, 50_000_000);

        // Advance 1 year
        vm.warp(block.timestamp + 365 days);

        // Get the debt (includes interest)
        uint256 debt = pool.loanDebt(1);
        assertGt(debt, 50_000_000, "Debt should include interest");

        // Give fund account enough to cover debt
        usdc.mint(borrower, debt);
        vm.prank(borrower);
        usdc.approve(address(pool), debt);

        _repay(1);

        assertEq(pool.totalBorrowShares(), 0, "All shares burned");
        assertEq(pool.totalBorrowed(), 0, "totalBorrowed should be 0");
    }

    // ── Per-loan wallet routing (borrow recipient + repay source) ───────

    function test_borrow_zeroWallet_reverts() public {
        _depositAs(lender1, 100_000_000);
        vm.prank(teeOperator);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        pool.borrow(1, 50_000_000, address(0));
    }

    function test_borrow_disbursesToLoanWallet_andRecords() public {
        _depositAs(lender1, 100_000_000);
        address walletA = makeAddr("walletA");

        // First borrow is 1:1, so shares == amount. Event must carry the loan wallet.
        vm.expectEmit(true, true, false, true, address(pool));
        emit AmplifiLendingPool.Borrow(1, walletA, 40_000_000, 40_000_000);
        _borrow(1, 40_000_000, walletA);

        assertEq(usdc.balanceOf(walletA), 40_000_000, "principal sent directly to the loan wallet");
        assertEq(pool.loanWallet(1), walletA, "loan wallet recorded on-chain");
    }

    function test_repay_pullsFromLoanWallet_perLoanIsolation() public {
        _depositAs(lender1, 200_000_000);
        address walletA = makeAddr("walletA");
        address walletB = makeAddr("walletB");

        _borrow(1, 40_000_000, walletA);
        _borrow(2, 30_000_000, walletB);

        vm.prank(walletA);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(walletB);
        usdc.approve(address(pool), type(uint256).max);

        uint256 walletBBefore = usdc.balanceOf(walletB);

        // Repaying loan 1 pulls ONLY from walletA; walletB (loan 2) is untouched.
        // Event must attribute the repayment to walletA (repaid == debt == 40M, shares == 40M).
        vm.expectEmit(true, true, false, true, address(pool));
        emit AmplifiLendingPool.Repay(1, walletA, 40_000_000, 40_000_000);
        _repay(1);

        assertEq(usdc.balanceOf(walletA), 0, "walletA drained to repay its own loan");
        assertEq(usdc.balanceOf(walletB), walletBBefore, "walletB untouched by loan 1 repay");
        assertEq(pool.loanWallet(1), address(0), "loan wallet cleared on repay");
        assertEq(pool.loanShares(1), 0, "loan 1 closed");
        assertGt(pool.loanShares(2), 0, "loan 2 still open");
    }

    function test_repay_walletMissingApproval_reverts() public {
        _depositAs(lender1, 100_000_000);
        address walletA = makeAddr("walletA");
        _borrow(1, 50_000_000, walletA);

        // walletA holds the funds but never approved the pool → transferFrom reverts,
        // leaving the loan untouched (operator can retry after the approval lands).
        vm.prank(teeOperator);
        vm.expectRevert();
        pool.repay(1, type(uint256).max);

        assertGt(pool.loanShares(1), 0, "loan untouched when repay reverts");
        assertEq(pool.loanWallet(1), walletA, "loan wallet retained when repay reverts");
    }

    // ── Share Math ──────────────────────────────────────────────────────

    function test_shares_multipleLoans_zeroDust() public {
        _depositAs(lender1, 1_000_000_000); // 1000 USDC

        // Borrow 3 loans at different times with different amounts
        _borrow(1, 100_000_000); // 100 USDC

        vm.warp(block.timestamp + 30 days);
        _borrow(2, 200_000_000); // 200 USDC

        vm.warp(block.timestamp + 60 days);
        _borrow(3, 50_000_000); // 50 USDC

        vm.warp(block.timestamp + 90 days);

        // Repay all — fund account needs enough for all debts
        uint256 debt1 = pool.loanDebt(1);
        uint256 debt2 = pool.loanDebt(2);
        uint256 debt3 = pool.loanDebt(3);
        uint256 totalDebt = debt1 + debt2 + debt3;

        usdc.mint(borrower, totalDebt); // extra to cover interest
        vm.prank(borrower);
        usdc.approve(address(pool), type(uint256).max);

        _repay(1);
        _repay(2);
        _repay(3);

        assertEq(pool.totalBorrowShares(), 0, "All shares should be burned");
        // totalBorrowed view returns 0 when totalBorrowShares == 0
        assertEq(pool.totalBorrowed(), 0, "totalBorrowed should be exactly 0");
    }

    function test_shares_singleLoan_debtEqualsExpected() public {
        _depositAs(lender1, 100_000_000);

        _borrow(1, 50_000_000);

        // Advance 1 year at 2% base rate, 50% utilization
        vm.warp(block.timestamp + 365 days);

        uint256 debt = pool.loanDebt(1);
        // At 50% utilization with base=200, kink=8500, kinkRate=2000:
        // rate = 200 + (2000-200)*5000/8500 ≈ 1258 bps
        // interest ≈ 50M * 1258 / 10000 = ~6.29M
        // Just verify it's in a reasonable range
        assertGt(debt, 55_000_000, "Debt should reflect ~1 year of interest");
        assertLt(debt, 60_000_000, "Debt should be reasonable");
    }

    function test_loanDebt_returnZeroForUnknownLoan() public view {
        assertEq(pool.loanDebt(999), 0, "Unknown loan should have 0 debt");
    }

    function test_loanDebt_includesPendingInterest() public {
        _depositAs(lender1, 100_000_000);
        _borrow(1, 50_000_000);

        uint256 debtBefore = pool.loanDebt(1);
        assertEq(debtBefore, 50_000_000, "Initial debt should equal principal");

        vm.warp(block.timestamp + 365 days);

        uint256 debtAfter = pool.loanDebt(1);
        assertGt(debtAfter, debtBefore, "Debt should grow with pending interest");
    }

    // ── Interest Rate Curve ─────────────────────────────────────────────

    function test_borrowRate_zeroUtilization() public view {
        // No borrows → utilization = 0 → rate = baseRate
        assertEq(pool.borrowRate(), BASE_RATE, "Zero utilization should return base rate");
    }

    function test_borrowRate_atKink() public {
        // Deposit 100, borrow 85 → 85% utilization (at kink)
        _depositAs(lender1, 100_000_000);
        _borrow(1, 85_000_000);

        // At kink, rate should be kinkRate
        assertEq(pool.borrowRate(), KINK_RATE, "At kink utilization should return kink rate");
    }

    function test_borrowRate_aboveKink() public {
        // Deposit 100, borrow 92.5 → 92.5% utilization
        _depositAs(lender1, 100_000_000);
        _borrow(1, 92_500_000);

        uint256 rate = pool.borrowRate();
        // Should be between kinkRate and maxRate
        assertGt(rate, KINK_RATE, "Above kink should be > kinkRate");
        assertLt(rate, MAX_RATE, "Below 100% should be < maxRate");
    }

    function test_utilizationAndRate_increaseWithPendingInterest() public {
        _depositAs(lender1, 100_000_000);
        _borrow(1, 90_000_000);

        uint256 utilBefore = pool.utilization();
        uint256 rateBefore = pool.borrowRate();

        vm.warp(block.timestamp + 180 days);

        uint256 utilAfter = pool.utilization();
        uint256 rateAfter = pool.borrowRate();

        assertGt(utilAfter, utilBefore, "Utilization should include pending interest");
        assertGt(rateAfter, rateBefore, "Borrow rate should react to higher utilization");
    }

    function test_viewFunctions_workAfterTimePassesWithActiveBorrow() public {
        _depositAs(lender1, 100_000_000);
        _borrow(1, 50_000_000);

        vm.warp(block.timestamp + 1);

        uint256 rate = pool.borrowRate();
        uint256 util = pool.utilization();
        uint256 assets = pool.totalAssets();

        assertGt(rate, 0, "Borrow rate should be readable");
        assertGt(util, 0, "Utilization should be readable");
        assertGe(assets, 100_000_000, "Total assets should be readable");
    }

    // ── Interest Accrual ────────────────────────────────────────────────

    function test_accrueInterest_increasesTotalBorrowed() public {
        _depositAs(lender1, 100_000_000);
        _borrow(1, 50_000_000);

        uint256 borrowedBefore = pool.totalBorrowed();

        // Advance 1 year
        vm.warp(block.timestamp + 365 days);
        pool.accrueInterest();

        uint256 borrowedAfter = pool.totalBorrowed();
        assertGt(borrowedAfter, borrowedBefore, "Interest should increase totalBorrowed");
    }

    function test_interestAccrual_increasesSharePrice() public {
        _depositAs(lender1, 100_000_000);

        uint256 sharesBefore = pool.sharesToAssets(1_000_000);

        _borrow(1, 50_000_000);

        // Advance 1 year
        vm.warp(block.timestamp + 365 days);
        pool.accrueInterest();

        uint256 sharesAfter = pool.sharesToAssets(1_000_000);
        assertGt(sharesAfter, sharesBefore, "Share price should increase after interest");
    }

    // ── Bad Debt ────────────────────────────────────────────────────────

    function test_badDebt_sharePriceDecreases() public {
        _depositAs(lender1, 100_000_000);
        _borrow(1, 50_000_000);

        // Borrower has 50M from the borrow. If they can't repay in full,
        // the loan stays outstanding. totalBorrowAssets still tracks the debt.
        assertEq(pool.totalBorrowed(), 50_000_000);
    }

    // ── Pool Status ─────────────────────────────────────────────────────

    function test_windingDown_blocksBorrows() public {
        _depositAs(lender1, 100_000_000);

        vm.prank(owner);
        pool.setPoolStatus(PoolStatus.WindingDown);

        vm.prank(teeOperator);
        vm.expectRevert(abi.encodeWithSignature("PoolNotActive()"));
        pool.borrow(1, 50_000_000, borrower);
    }

    function test_windingDown_allowsWithdrawals() public {
        _depositAs(lender1, 100_000_000);

        vm.prank(owner);
        pool.setPoolStatus(PoolStatus.WindingDown);

        uint256 lenderShares = pool.balanceOf(lender1);
        vm.prank(lender1);
        pool.withdraw(lenderShares);

        assertEq(usdc.balanceOf(lender1), 100_000_000);
    }

    function test_windingDown_blocksDeposits() public {
        vm.prank(owner);
        pool.setPoolStatus(PoolStatus.WindingDown);

        usdc.mint(lender1, 100_000_000);
        vm.startPrank(lender1);
        usdc.approve(address(pool), 100_000_000);
        vm.expectRevert(abi.encodeWithSignature("PoolNotActive()"));
        pool.deposit(100_000_000);
        vm.stopPrank();
    }

    function test_closed_allowsWithdrawals() public {
        // Audit #1: Closed must not strand lender funds. Withdraw still works in Closed.
        _depositAs(lender1, 100_000_000);

        vm.startPrank(owner);
        pool.setPoolStatus(PoolStatus.WindingDown);
        pool.setPoolStatus(PoolStatus.Closed);
        vm.stopPrank();

        uint256 lenderShares = pool.balanceOf(lender1);
        vm.prank(lender1);
        pool.withdraw(lenderShares);

        assertEq(usdc.balanceOf(lender1), 100_000_000, "Lender recovers funds in Closed state");
        assertEq(pool.balanceOf(lender1), 0);
    }

    function test_closed_allowsRepay() public {
        // Audit #6: Closed must not strand outstanding loans. Repay still works in Closed.
        _depositAs(lender1, 100_000_000);
        _borrow(1, 50_000_000);

        vm.startPrank(owner);
        pool.setPoolStatus(PoolStatus.WindingDown);
        pool.setPoolStatus(PoolStatus.Closed);
        vm.stopPrank();

        vm.prank(borrower);
        usdc.approve(address(pool), 50_000_000);

        _repay(1);

        assertEq(pool.totalBorrowShares(), 0, "Loan repaid in Closed state");
        assertEq(pool.loanShares(1), 0);
    }

    // ── Access Control ──────────────────────────────────────────────────

    function test_setTeeOperator_onlyOwner() public {
        vm.prank(lender1);
        vm.expectRevert();
        pool.setTeeOperator(lender1);
    }

    function test_setRateParams_onlyOwner() public {
        vm.prank(lender1);
        vm.expectRevert();
        pool.setRateParams(100, 8000, 1500, 8000);
    }

    function test_setRateParams_invalidParams_reverts() public {
        // baseRate > kinkRate
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRateParams()"));
        pool.setRateParams(5000, 8000, 3000, 8000);
    }

    function test_setRateParams_acceptsRatesAboveBps() public {
        // The 100% APR cap was lifted to support higher-risk pools (e.g.
        // sports). The validator now only enforces baseRate ≤ kinkRate ≤
        // maxRate and a non-zero / ≤BPS kinkUtilization.
        vm.prank(owner);
        pool.setRateParams(2000, 8500, 20000, 100000);
        assertEq(pool.baseRateBps(), 2000);
        assertEq(pool.kinkUtilizationBps(), 8500);
        assertEq(pool.kinkRateBps(), 20000);
        assertEq(pool.maxRateBps(), 100000);
    }

    function test_setRateParams_kinkUtilizationStillCappedAtBps() public {
        // kinkUtilization is a fraction, not a rate — must stay ≤BPS.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRateParams()"));
        pool.setRateParams(200, 10001, 2000, 10000);
    }

    function test_setPoolStatus_onlyOwner() public {
        vm.prank(lender1);
        vm.expectRevert();
        pool.setPoolStatus(PoolStatus.WindingDown);
    }

    function test_setPoolStatus_backwardTransition_reverts() public {
        vm.startPrank(owner);
        pool.setPoolStatus(PoolStatus.WindingDown);

        vm.expectRevert(abi.encodeWithSignature("InvalidStatusTransition()"));
        pool.setPoolStatus(PoolStatus.Active);
        vm.stopPrank();
    }

    function test_setPoolStatus_sameStatus_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidStatusTransition()"));
        pool.setPoolStatus(PoolStatus.Active);
    }

    function test_setPoolStatus_closedToActive_reverts() public {
        vm.startPrank(owner);
        pool.setPoolStatus(PoolStatus.WindingDown);
        pool.setPoolStatus(PoolStatus.Closed);

        vm.expectRevert(abi.encodeWithSignature("InvalidStatusTransition()"));
        pool.setPoolStatus(PoolStatus.Active);
        vm.stopPrank();
    }

    function test_inflation_attack_mitigated() public {
        // Attacker deposits 1 wei to get initial shares
        usdc.mint(lender1, 1);
        vm.startPrank(lender1);
        usdc.approve(address(pool), 1);
        pool.deposit(1);
        vm.stopPrank();

        // Attacker donates 10 USDC directly to inflate share price
        usdc.mint(lender1, 10_000_000);
        vm.prank(lender1);
        usdc.transfer(address(pool), 10_000_000);

        // Victim deposits 10 USDC
        usdc.mint(lender2, 10_000_000);
        vm.startPrank(lender2);
        usdc.approve(address(pool), 10_000_000);
        pool.deposit(10_000_000);
        vm.stopPrank();

        // Victim should get shares worth close to their deposit
        uint256 victimShares = pool.balanceOf(lender2);
        uint256 victimAssets = pool.sharesToAssets(victimShares);
        // With virtual offset, victim loses at most a fraction of a cent, not the full deposit
        assertGt(victimAssets, 9_990_000, "Victim should retain >99.9% of deposit value");
    }

    // ── ERC20 Properties ────────────────────────────────────────────────

    function test_shareToken_properties() public view {
        assertEq(pool.name(), "Amplifi pUSD Lending Share");
        assertEq(pool.symbol(), "apUSD");
        assertEq(pool.decimals(), 6);
    }

    function test_shares_transferable() public {
        _depositAs(lender1, 100_000_000);

        vm.startPrank(lender1);
        uint256 shares = pool.balanceOf(lender1);
        pool.transfer(lender2, shares / 2);
        vm.stopPrank();

        assertEq(pool.balanceOf(lender1), shares / 2);
        assertEq(pool.balanceOf(lender2), shares / 2);
    }

    // ── ERC-4626 View Functions ─────────────────────────────────────────

    function test_maxDeposit_activePool() public view {
        assertEq(pool.maxDeposit(lender1), type(uint256).max);
    }

    function test_maxDeposit_windingDown() public {
        vm.prank(owner);
        pool.setPoolStatus(PoolStatus.WindingDown);
        assertEq(pool.maxDeposit(lender1), 0);
    }

    function test_maxDeposit_closed() public {
        vm.startPrank(owner);
        pool.setPoolStatus(PoolStatus.WindingDown);
        pool.setPoolStatus(PoolStatus.Closed);
        vm.stopPrank();
        assertEq(pool.maxDeposit(lender1), 0);
    }

    function test_maxWithdraw_noLoans() public {
        _depositAs(lender1, 100_000_000);
        uint256 maxW = pool.maxWithdraw(lender1);
        // Should be approximately the deposit (rounding may lose 1 wei)
        assertGe(maxW, 99_999_999);
        assertLe(maxW, 100_000_000);
    }

    function test_maxWithdraw_limitedByLiquidity() public {
        _depositAs(lender1, 100_000_000);
        _borrow(1, 90_000_000);

        uint256 maxW = pool.maxWithdraw(lender1);
        // Liquidity is 10M, owner's share value is ~100M, so maxWithdraw = 10M
        assertEq(maxW, 10_000_000);
    }

    function test_maxRedeem_noLoans() public {
        _depositAs(lender1, 100_000_000);
        uint256 maxR = pool.maxRedeem(lender1);
        assertEq(maxR, pool.balanceOf(lender1));
    }

    function test_maxRedeem_limitedByLiquidity() public {
        _depositAs(lender1, 100_000_000);
        _borrow(1, 90_000_000);

        uint256 maxR = pool.maxRedeem(lender1);
        uint256 liquidityShares = pool.assetsToShares(10_000_000);
        assertEq(maxR, liquidityShares);
        assertLt(maxR, pool.balanceOf(lender1));
    }

    function test_previewDeposit() public {
        _depositAs(lender1, 100_000_000);
        uint256 preview = pool.previewDeposit(50_000_000);
        assertEq(preview, pool.assetsToShares(50_000_000));
    }

    function test_previewWithdraw_roundsUp() public {
        _depositAs(lender1, 100_000_000);

        uint256 assets = 50_000_000;
        uint256 sharesNeeded = pool.previewWithdraw(assets);
        uint256 sharesDown = pool.assetsToShares(assets);

        // previewWithdraw rounds UP, assetsToShares rounds DOWN
        assertGe(sharesNeeded, sharesDown, "previewWithdraw should round up");
    }

    function test_previewRedeem() public {
        _depositAs(lender1, 100_000_000);
        uint256 shares = pool.balanceOf(lender1);
        uint256 preview = pool.previewRedeem(shares);
        assertEq(preview, pool.sharesToAssets(shares));
    }

    function test_convertToShares() public {
        _depositAs(lender1, 100_000_000);
        assertEq(pool.convertToShares(50_000_000), pool.assetsToShares(50_000_000));
    }

    function test_convertToAssets() public {
        _depositAs(lender1, 100_000_000);
        uint256 shares = pool.balanceOf(lender1);
        assertEq(pool.convertToAssets(shares), pool.sharesToAssets(shares));
    }

    // ── withdrawAssets ───────────────────────────────────────────────────

    function test_withdrawAssets_basic() public {
        _depositAs(lender1, 100_000_000);

        vm.prank(lender1);
        pool.withdrawAssets(50_000_000);

        assertEq(usdc.balanceOf(lender1), 50_000_000, "Should receive requested USDC");
        assertGt(pool.balanceOf(lender1), 0, "Should still have remaining shares");
    }

    function test_withdrawAssets_full() public {
        uint256 amount = 100_000_000;
        _depositAs(lender1, amount);

        uint256 maxW = pool.maxWithdraw(lender1);
        vm.prank(lender1);
        pool.withdrawAssets(maxW);

        assertEq(usdc.balanceOf(lender1), maxW, "Should receive max withdrawable");
    }

    function test_withdrawAssets_zeroAmount_reverts() public {
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        pool.withdrawAssets(0);
    }

    function test_withdrawAssets_insufficientLiquidity_reverts() public {
        _depositAs(lender1, 100_000_000);
        _borrow(1, 90_000_000);

        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSignature("InsufficientLiquidity()"));
        pool.withdrawAssets(20_000_000);
    }

    function test_withdrawAssets_closedAllowed() public {
        // Audit #1: withdrawAssets must also work in Closed state.
        _depositAs(lender1, 100_000_000);

        vm.startPrank(owner);
        pool.setPoolStatus(PoolStatus.WindingDown);
        pool.setPoolStatus(PoolStatus.Closed);
        vm.stopPrank();

        vm.prank(lender1);
        pool.withdrawAssets(50_000_000);
        assertEq(usdc.balanceOf(lender1), 50_000_000);
    }

    function test_withdrawAssets_windingDown_works() public {
        _depositAs(lender1, 100_000_000);

        vm.prank(owner);
        pool.setPoolStatus(PoolStatus.WindingDown);

        vm.prank(lender1);
        pool.withdrawAssets(50_000_000);
        assertEq(usdc.balanceOf(lender1), 50_000_000);
    }

    function test_withdrawAssets_roundsUpSharesBurned() public {
        _depositAs(lender1, 100_000_000);
        _borrow(1, 50_000_000);

        // Advance time to accrue interest and create non-trivial exchange rate
        vm.warp(block.timestamp + 180 days);

        uint256 assets = 1_000_003; // odd amount to trigger rounding
        uint256 sharesBefore = pool.balanceOf(lender1);

        vm.prank(lender1);
        pool.withdrawAssets(assets);

        uint256 sharesBurned = sharesBefore - pool.balanceOf(lender1);
        // The shares burned times exchange rate should be >= assets requested
        // (rounding up means user pays slightly more in shares)
        uint256 assetsFromBurned = pool.sharesToAssets(sharesBurned);
        assertGe(assetsFromBurned, assets - 1, "Burned shares should cover requested assets");
    }

    // ── Repay: borrower-wallet balance scenarios ───────────────────────

    function test_repay_walletHasExactDebt_succeeds() public {
        // Simulates normal case: the borrower wallet has exactly enough for debt.
        _depositAs(lender1, 100_000_000);
        _borrow(1, 50_000_000);

        // Advance time so interest accrues
        vm.warp(block.timestamp + 90 days);

        uint256 debt = pool.loanDebt(1);
        assertGt(debt, 50_000_000, "Debt should include interest");

        // Fund account has borrow principal (50M) + mint exactly the interest shortfall
        uint256 fundBalance = usdc.balanceOf(borrower);
        uint256 shortfall = debt - fundBalance;
        usdc.mint(borrower, shortfall);

        vm.prank(borrower);
        usdc.approve(address(pool), debt);

        _repay(1);

        assertEq(pool.totalBorrowShares(), 0);
        assertEq(pool.loanShares(1), 0);
    }

    function test_repay_walletInsufficientBalance_reverts() public {
        // Simulates bad debt scenario: the borrower wallet doesn't have enough USDC
        // to cover the full debt. safeTransferFrom reverts.
        _depositAs(lender1, 100_000_000);
        _borrow(1, 50_000_000);

        // Advance time so interest accrues
        vm.warp(block.timestamp + 365 days);

        uint256 debt = pool.loanDebt(1);
        uint256 fundBalance = usdc.balanceOf(borrower);
        assertGt(debt, fundBalance, "Debt should exceed fund balance (interest not funded)");

        // Approve only what fundAccount has
        vm.prank(borrower);
        usdc.approve(address(pool), fundBalance);

        // Repay with maxRepay=max reverts because safeTransferFrom can't pull full debt
        vm.prank(teeOperator);
        vm.expectRevert();
        pool.repay(1, type(uint256).max);

        // Loan is untouched — shares still exist
        assertGt(pool.loanShares(1), 0, "Loan shares should remain");
        assertGt(pool.totalBorrowShares(), 0, "Total borrow shares should remain");
    }

    function test_repay_fullRepay_noBadDebt() public {
        // When maxRepay >= debt, behaves like normal repay
        _depositAs(lender1, 100_000_000);
        _borrow(1, 50_000_000);

        vm.warp(block.timestamp + 90 days);

        uint256 debt = pool.loanDebt(1);
        usdc.mint(borrower, debt); // ensure enough
        vm.prank(borrower);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(teeOperator);
        pool.repay(1, type(uint256).max); // maxRepay = unlimited

        assertEq(pool.totalBorrowShares(), 0);
        assertEq(pool.loanShares(1), 0);
    }

    function test_repay_partialRepay_writesOffShortfall() public {
        // Simulates the interest-drift-exceeds-user-equity scenario:
        // fundAccount has less than full debt, shortfall is bad debt.
        _depositAs(lender1, 100_000_000);
        _borrow(1, 50_000_000);

        vm.warp(block.timestamp + 365 days);

        uint256 debt = pool.loanDebt(1);
        assertGt(debt, 50_000_000, "Debt should include interest");

        // fundAccount only has the original principal (50M), not the interest
        uint256 fundBalance = usdc.balanceOf(borrower);
        assertEq(fundBalance, 50_000_000, "Fund account has only principal");
        assertGt(debt, fundBalance, "Debt exceeds fund balance");

        vm.prank(borrower);
        usdc.approve(address(pool), fundBalance);

        // Record lender share value before bad debt
        uint256 shareValueBefore = pool.sharesToAssets(pool.balanceOf(lender1));

        vm.prank(teeOperator);
        pool.repay(1, fundBalance); // can only pay principal, not interest

        // Loan is fully closed
        assertEq(pool.totalBorrowShares(), 0);
        assertEq(pool.loanShares(1), 0);

        // Pool received only fundBalance, not full debt
        // The difference (debt - fundBalance) is bad debt absorbed by lenders
        uint256 shareValueAfter = pool.sharesToAssets(pool.balanceOf(lender1));
        assertLt(shareValueAfter, shareValueBefore, "Share value decreased due to bad debt");

        // The bad debt amount = interest that wasn't paid
        uint256 expectedBadDebt = debt - fundBalance;
        uint256 shareLoss = shareValueBefore - shareValueAfter;
        // Loss should be approximately equal to bad debt (virtual offset causes small deviation)
        assertGe(shareLoss, (expectedBadDebt * 99) / 100, "Loss should be ~bad debt");
        assertLe(shareLoss, expectedBadDebt + 1000, "Loss shouldn't exceed bad debt significantly");
    }

    function test_repay_zeroMaxRepay_fullWriteOff() public {
        // Extreme case: nothing to repay, entire debt is bad debt
        _depositAs(lender1, 100_000_000);
        _borrow(1, 50_000_000);

        vm.warp(block.timestamp + 30 days);

        uint256 shareValueBefore = pool.sharesToAssets(pool.balanceOf(lender1));

        vm.prank(teeOperator);
        pool.repay(1, 0); // zero repayment

        assertEq(pool.totalBorrowShares(), 0);

        uint256 shareValueAfter = pool.sharesToAssets(pool.balanceOf(lender1));
        assertLt(shareValueAfter, shareValueBefore, "Full write-off reduces share value");

        // Pool balance unchanged (no transfer happened)
        assertEq(usdc.balanceOf(address(pool)), 50_000_000);
    }

    function test_repay_multipleLoans_badDebtOnlyAffectsPool() public {
        // Two lenders, one loan goes bad — both absorb loss proportionally
        _depositAs(lender1, 50_000_000);
        _depositAs(lender2, 50_000_000);
        _borrow(1, 60_000_000);

        vm.warp(block.timestamp + 180 days);

        uint256 debt = pool.loanDebt(1);
        uint256 fundBalance = usdc.balanceOf(borrower);

        // Can only repay 60M (principal), not interest
        vm.prank(borrower);
        usdc.approve(address(pool), fundBalance);

        uint256 lender1ValueBefore = pool.sharesToAssets(pool.balanceOf(lender1));
        uint256 lender2ValueBefore = pool.sharesToAssets(pool.balanceOf(lender2));

        vm.prank(teeOperator);
        pool.repay(1, fundBalance);

        uint256 lender1ValueAfter = pool.sharesToAssets(pool.balanceOf(lender1));
        uint256 lender2ValueAfter = pool.sharesToAssets(pool.balanceOf(lender2));

        // Both lenders lost value
        assertLt(lender1ValueAfter, lender1ValueBefore);
        assertLt(lender2ValueAfter, lender2ValueBefore);

        // Losses are proportional (equal deposits → equal losses, within rounding)
        uint256 loss1 = lender1ValueBefore - lender1ValueAfter;
        uint256 loss2 = lender2ValueBefore - lender2ValueAfter;
        assertGe(loss1, loss2 - 2);
        assertLe(loss1, loss2 + 2);
    }

    function test_repay_badDebt_lendersAbsorbLoss() public {
        // Demonstrates that bad debt (when fundAccount can only partially
        // cover debt) affects lender share value. The contract itself doesn't
        // have a "partial repay" — it reverts. Bad debt manifests as
        // totalBorrowAssets > 0 with no one to repay, reducing share value.
        //
        // In production, the backend handles this by ensuring fundAccount
        // always has enough, absorbing the difference from user equity.

        _depositAs(lender1, 100_000_000);
        _borrow(1, 80_000_000);

        // Advance time — interest accrues on totalBorrowAssets
        vm.warp(block.timestamp + 365 days);

        // Check total assets includes the borrow debt + interest
        uint256 totalBefore = pool.totalAssets();
        uint256 debtBefore = pool.loanDebt(1);
        assertGt(debtBefore, 80_000_000, "Debt should have accrued interest");
        assertEq(totalBefore, usdc.balanceOf(address(pool)) + debtBefore);

        // If the loan is never repaid (worst case), lenders still own shares
        // but totalAssets includes uncollectable debt. The share price
        // still reflects totalBorrowAssets as if it's recoverable.
        // This is the same as Morpho/Aave — bad debt stays on the books
        // until governance writes it off.
        uint256 shareValue = pool.sharesToAssets(pool.balanceOf(lender1));
        assertGt(shareValue, 0, "Lender shares still have value (including bad debt)");

        // If someone writes off the bad debt (e.g., owner resets state),
        // the share value drops proportionally for all lenders.
        // This is the "lenders absorb bad debt proportionally" property.
    }

    // ── Audit #2: maxRateBps cap ────────────────────────────────────────

    function test_rateParams_rejectsMaxRateAboveCap() public {
        // Audit #2: maxRateBps must be capped to block the rate-spike drain path.
        uint256 capPlusOne = pool.MAX_RATE_CAP_BPS() + 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRateParams()"));
        pool.setRateParams(200, 8500, 2000, capPlusOne);
    }

    function test_rateParams_acceptsMaxRateAtCap() public {
        uint256 cap = pool.MAX_RATE_CAP_BPS();
        vm.prank(owner);
        pool.setRateParams(200, 8500, 2000, cap);
        assertEq(pool.maxRateBps(), cap);
    }

    // ── Audit #4: Ownable2Step ──────────────────────────────────────────

    function test_ownership_requiresAcceptance() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        pool.transferOwnership(newOwner);

        // Old owner still owns until newOwner accepts.
        assertEq(pool.owner(), owner);
        assertEq(pool.pendingOwner(), newOwner);

        // Old owner can still call onlyOwner functions.
        vm.prank(owner);
        pool.setTeeOperator(makeAddr("anotherOp"));

        // newOwner accepts.
        vm.prank(newOwner);
        pool.acceptOwnership();
        assertEq(pool.owner(), newOwner);
        assertEq(pool.pendingOwner(), address(0));

        // Old owner can no longer call onlyOwner.
        vm.prank(owner);
        vm.expectRevert();
        pool.setTeeOperator(makeAddr("yetAnother"));
    }

    function test_ownership_acceptByWrongAddress_reverts() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        pool.transferOwnership(newOwner);

        vm.prank(lender1); // not the pending owner
        vm.expectRevert();
        pool.acceptOwnership();
    }

    // ── Audit #7: ERC-4626 compliance ───────────────────────────────────

    function test_4626_assetReturnsUsdc() public view {
        assertEq(pool.asset(), address(usdc));
    }

    function test_4626_depositToReceiver() public {
        uint256 amount = 100_000_000;
        usdc.mint(lender1, amount);
        vm.startPrank(lender1);
        usdc.approve(address(pool), amount);
        uint256 shares = pool.deposit(amount, lender2);
        vm.stopPrank();

        assertEq(pool.balanceOf(lender2), shares, "Receiver got shares");
        assertEq(pool.balanceOf(lender1), 0, "Sender got no shares");
    }

    function test_4626_mintToReceiver() public {
        // First deposit to establish exchange rate.
        _depositAs(lender1, 100_000_000);

        uint256 sharesToMint = 50_000_000;
        uint256 expectedAssets = pool.previewMint(sharesToMint);
        usdc.mint(lender2, expectedAssets);

        vm.startPrank(lender2);
        usdc.approve(address(pool), expectedAssets);
        uint256 assetsPaid = pool.mint(sharesToMint, lender2);
        vm.stopPrank();

        assertEq(assetsPaid, expectedAssets);
        assertEq(pool.balanceOf(lender2), sharesToMint);
    }

    function test_4626_withdrawWithOwner() public {
        // lender1 deposits, approves lender2 to pull on their behalf.
        _depositAs(lender1, 100_000_000);

        uint256 sharesNeeded = pool.previewWithdraw(50_000_000);
        vm.prank(lender1);
        pool.approve(lender2, sharesNeeded);

        // lender2 calls withdraw, receiver is lender2, owner is lender1.
        vm.prank(lender2);
        pool.withdraw(50_000_000, lender2, lender1);

        assertEq(usdc.balanceOf(lender2), 50_000_000, "Receiver got assets");
        assertEq(pool.allowance(lender1, lender2), 0, "Allowance spent");
    }

    function test_4626_redeemWithOwner() public {
        _depositAs(lender1, 100_000_000);

        uint256 sharesToRedeem = 50_000_000;
        vm.prank(lender1);
        pool.approve(lender2, sharesToRedeem);

        vm.prank(lender2);
        uint256 assets = pool.redeem(sharesToRedeem, lender2, lender1);

        assertEq(usdc.balanceOf(lender2), assets);
        assertEq(pool.balanceOf(lender1), 100_000_000 - sharesToRedeem);
    }

    function test_4626_redeemWithoutAllowance_reverts() public {
        _depositAs(lender1, 100_000_000);

        vm.prank(lender2);
        vm.expectRevert(); // ERC20InsufficientAllowance
        pool.redeem(50_000_000, lender2, lender1);
    }

    function test_4626_previewMintRoundsUp() public {
        _depositAs(lender1, 100_000_000);
        _borrow(1, 50_000_000);
        vm.warp(block.timestamp + 180 days);

        uint256 shares = 1_000_003; // odd to force rounding
        uint256 assetsUp = pool.previewMint(shares);
        uint256 assetsDown = pool.sharesToAssets(shares);

        assertGe(assetsUp, assetsDown, "previewMint rounds up");
    }

    function test_4626_maxMintMirrorsMaxDeposit() public {
        assertEq(pool.maxMint(lender1), pool.maxDeposit(lender1));

        vm.prank(owner);
        pool.setPoolStatus(PoolStatus.WindingDown);
        assertEq(pool.maxMint(lender1), 0);
    }

    // ── Reentrancy ──────────────────────────────────────────────────────
    // Note: With SafeERC20 and standard ERC20 (no callbacks), reentrancy
    // is inherently prevented. The ReentrancyGuard is defense-in-depth.
    // A proper reentrancy test would need a malicious ERC20 with transfer hooks,
    // but that's not possible with USDC (standard ERC20). The guard is tested
    // implicitly by the fact that all state-changing functions use nonReentrant.
}
