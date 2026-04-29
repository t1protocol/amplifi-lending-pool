// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

enum PoolStatus {
    Active,
    WindingDown,
    Closed
}

contract AmplifiLendingPool is ERC20, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ── Immutables ──────────────────────────────────────────────────────
    IERC20 public immutable usdc;

    // ── State ───────────────────────────────────────────────────────────
    address public teeOperator;
    address public fundAccount;
    PoolStatus public status;
    uint256 public totalBorrowAssets;
    uint256 public totalBorrowShares;
    uint256 public lastAccrualTimestamp;

    // ── Loan tracking ─────────────────────────────────────────────────
    mapping(uint256 => uint256) public loanShares;

    // ── Interest Rate Model ─────────────────────────────────────────────
    uint256 public baseRateBps;
    uint256 public kinkUtilizationBps;
    uint256 public kinkRateBps;
    uint256 public maxRateBps;

    // ── Constants ───────────────────────────────────────────────────────
    uint256 private constant BPS = 10_000;
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    // Virtual offset to mitigate ERC-4626 first-depositor inflation attack.
    // See: https://docs.openzeppelin.com/contracts/5.x/erc4626#defending_with_a_virtual_offset
    uint256 private constant VIRTUAL_SHARES = 1e3;
    uint256 private constant VIRTUAL_ASSETS = 1e3;

    // ── Events ──────────────────────────────────────────────────────────
    event Deposit(address indexed depositor, uint256 assets, uint256 shares);
    event Withdraw(address indexed withdrawer, uint256 shares, uint256 assets);
    event Borrow(uint256 indexed loanId, uint256 amount, uint256 shares);
    event Repay(uint256 indexed loanId, uint256 repaid, uint256 shares);
    event BadDebtRealized(uint256 indexed loanId, uint256 badDebt);
    event FundAccountUpdated(address indexed oldAccount, address indexed newAccount);
    event InterestAccrued(uint256 interest, uint256 newTotalBorrowAssets);
    event TeeOperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event RateParamsUpdated(uint256 baseRateBps, uint256 kinkUtilizationBps, uint256 kinkRateBps, uint256 maxRateBps);
    event PoolStatusUpdated(PoolStatus oldStatus, PoolStatus newStatus);

    // ── Errors ──────────────────────────────────────────────────────────
    error OnlyTeeOperator();
    error PoolNotActive();
    error PoolClosed();
    error InsufficientLiquidity();
    error ZeroAmount();
    error ZeroShares();
    error InvalidRateParams();
    error InvalidStatusTransition();
    error ZeroAddress();
    error LoanAlreadyExists();
    error LoanNotFound();

    // ── Modifiers ───────────────────────────────────────────────────────
    modifier onlyTeeOperator() {
        if (msg.sender != teeOperator) revert OnlyTeeOperator();
        _;
    }

    modifier whenActive() {
        if (status != PoolStatus.Active) revert PoolNotActive();
        _;
    }

    modifier whenNotClosed() {
        if (status == PoolStatus.Closed) revert PoolClosed();
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────
    constructor(
        address _usdc,
        address _owner,
        address _teeOperator,
        address _fundAccount,
        uint256 _baseRateBps,
        uint256 _kinkUtilizationBps,
        uint256 _kinkRateBps,
        uint256 _maxRateBps
    ) ERC20("Amplifi Lending Share", "aUSDC") Ownable(_owner) {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_teeOperator == address(0)) revert ZeroAddress();
        if (_fundAccount == address(0)) revert ZeroAddress();
        usdc = IERC20(_usdc);
        teeOperator = _teeOperator;
        fundAccount = _fundAccount;
        baseRateBps = _baseRateBps;
        kinkUtilizationBps = _kinkUtilizationBps;
        kinkRateBps = _kinkRateBps;
        maxRateBps = _maxRateBps;
        lastAccrualTimestamp = block.timestamp;

        _validateRateParams(_baseRateBps, _kinkUtilizationBps, _kinkRateBps, _maxRateBps);
    }

    // ── ERC20 Overrides ─────────────────────────────────────────────────
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // ── Core Functions ──────────────────────────────────────────────────

    function deposit(uint256 assets) external nonReentrant whenActive {
        if (assets == 0) revert ZeroAmount();
        accrueInterest();

        uint256 shares = assetsToShares(assets);
        if (shares == 0) revert ZeroShares();

        usdc.safeTransferFrom(msg.sender, address(this), assets);
        _mint(msg.sender, shares);

        emit Deposit(msg.sender, assets, shares);
    }

    function withdraw(uint256 shares) external nonReentrant whenNotClosed {
        if (shares == 0) revert ZeroShares();
        accrueInterest();

        uint256 assets = sharesToAssets(shares);
        if (assets == 0) revert ZeroAmount();
        if (assets > availableLiquidity()) revert InsufficientLiquidity();

        _burn(msg.sender, shares);
        usdc.safeTransfer(msg.sender, assets);

        emit Withdraw(msg.sender, shares, assets);
    }

    function borrow(uint256 loanId, uint256 amount) external nonReentrant onlyTeeOperator whenActive {
        if (amount == 0) revert ZeroAmount();
        if (loanShares[loanId] != 0) revert LoanAlreadyExists();

        accrueInterest();

        if (amount > availableLiquidity()) revert InsufficientLiquidity();

        uint256 shares = _borrowSharesToMint(amount);
        loanShares[loanId] = shares;
        totalBorrowShares += shares;
        totalBorrowAssets += amount;

        usdc.safeTransfer(fundAccount, amount);

        emit Borrow(loanId, amount, shares);
    }

    /// @notice Repay a loan, writing off any shortfall as bad debt absorbed by lenders.
    /// @dev Handles both full repayment and partial repayment in a single function.
    ///      When maxRepay >= debt, behaves as a normal full repay (no bad debt).
    ///      When maxRepay < debt (e.g., interest drift exceeded user equity during
    ///      bridging), the shortfall reduces totalBorrowAssets without corresponding
    ///      USDC inflow — lenders absorb the loss proportionally via reduced share price.
    function repay(uint256 loanId, uint256 maxRepay) external nonReentrant onlyTeeOperator whenNotClosed {
        uint256 shares = loanShares[loanId];
        if (shares == 0) revert LoanNotFound();

        accrueInterest();

        uint256 debt = _borrowAssetsOwed(shares);
        uint256 repaid = debt < maxRepay ? debt : maxRepay;
        uint256 badDebt = debt - repaid;

        delete loanShares[loanId];
        totalBorrowShares -= shares;
        totalBorrowAssets -= debt;

        if (repaid > 0) {
            usdc.safeTransferFrom(fundAccount, address(this), repaid);
        }

        emit Repay(loanId, repaid, shares);
        if (badDebt > 0) {
            emit BadDebtRealized(loanId, badDebt);
        }
    }

    // ── Interest ────────────────────────────────────────────────────────

    function accrueInterest() public {
        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        if (elapsed == 0) return;

        lastAccrualTimestamp = block.timestamp;

        if (totalBorrowAssets == 0) return;

        uint256 rate = borrowRate();
        uint256 interest = (totalBorrowAssets * rate * elapsed) / (BPS * SECONDS_PER_YEAR);

        if (interest > 0) {
            totalBorrowAssets += interest;
            emit InterestAccrued(interest, totalBorrowAssets);
        }
    }

    function borrowRate() public view returns (uint256) {
        return _borrowRateAtUtilization(utilization());
    }

    // ── View Functions ──────────────────────────────────────────────────

    function totalBorrowed() external view returns (uint256) {
        return totalBorrowAssets + _pendingInterest();
    }

    function loanDebt(uint256 loanId) external view returns (uint256) {
        uint256 shares = loanShares[loanId];
        if (shares == 0) return 0;
        uint256 adjustedAssets = totalBorrowAssets + _pendingInterest();
        return (shares * adjustedAssets + totalBorrowShares - 1) / totalBorrowShares;
    }

    function totalAssets() public view returns (uint256) {
        return usdc.balanceOf(address(this)) + totalBorrowAssets + _pendingInterest();
    }

    function availableLiquidity() public view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function utilization() public view returns (uint256) {
        if (totalBorrowAssets == 0) return 0;

        // Estimate pending interest using the last-accrued utilization-derived rate.
        // This avoids borrowRate() <-> _pendingInterest() recursion while keeping
        // utilization aligned with outstanding debt including unaccrued interest.
        uint256 baseUtil = _utilizationWithBorrowAssets(totalBorrowAssets);
        uint256 baseRate = _borrowRateAtUtilization(baseUtil);
        uint256 adjustedBorrowAssets = totalBorrowAssets + _pendingInterestAtRate(baseRate);
        return _utilizationWithBorrowAssets(adjustedBorrowAssets);
    }

    function sharesToAssets(uint256 shares) public view returns (uint256) {
        return (shares * (totalAssets() + VIRTUAL_ASSETS)) / (totalSupply() + VIRTUAL_SHARES);
    }

    function assetsToShares(uint256 assets) public view returns (uint256) {
        return (assets * (totalSupply() + VIRTUAL_SHARES)) / (totalAssets() + VIRTUAL_ASSETS);
    }

    function withdrawAssets(uint256 assets) external nonReentrant whenNotClosed {
        if (assets == 0) revert ZeroAmount();
        accrueInterest();

        if (assets > availableLiquidity()) revert InsufficientLiquidity();

        // Round UP: user burns more shares (favors pool)
        uint256 shares = previewWithdraw(assets);
        if (shares == 0) revert ZeroShares();

        _burn(msg.sender, shares);
        usdc.safeTransfer(msg.sender, assets);

        emit Withdraw(msg.sender, shares, assets);
    }

    // ── ERC-4626 View Functions ──────────────────────────────────────────

    function maxDeposit(address) external view returns (uint256) {
        return status == PoolStatus.Active ? type(uint256).max : 0;
    }

    function maxWithdraw(address _owner) external view returns (uint256) {
        uint256 ownerAssets = sharesToAssets(balanceOf(_owner));
        uint256 liquidity = availableLiquidity();
        return ownerAssets < liquidity ? ownerAssets : liquidity;
    }

    function maxRedeem(address _owner) external view returns (uint256) {
        uint256 ownerShares = balanceOf(_owner);
        uint256 liquidityShares = assetsToShares(availableLiquidity());
        return ownerShares < liquidityShares ? ownerShares : liquidityShares;
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return assetsToShares(assets);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        // Round UP (favors pool)
        return (assets * (totalSupply() + VIRTUAL_SHARES) + totalAssets() + VIRTUAL_ASSETS - 1) / (totalAssets() + VIRTUAL_ASSETS);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return sharesToAssets(shares);
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return assetsToShares(assets);
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return sharesToAssets(shares);
    }

    // ── Admin Functions ─────────────────────────────────────────────────

    function setTeeOperator(address _teeOperator) external onlyOwner {
        if (_teeOperator == address(0)) revert ZeroAddress();
        emit TeeOperatorUpdated(teeOperator, _teeOperator);
        teeOperator = _teeOperator;
    }

    function setFundAccount(address _fundAccount) external onlyOwner {
        if (_fundAccount == address(0)) revert ZeroAddress();
        emit FundAccountUpdated(fundAccount, _fundAccount);
        fundAccount = _fundAccount;
    }

    function setRateParams(
        uint256 _baseRateBps,
        uint256 _kinkUtilizationBps,
        uint256 _kinkRateBps,
        uint256 _maxRateBps
    ) external onlyOwner {
        _validateRateParams(_baseRateBps, _kinkUtilizationBps, _kinkRateBps, _maxRateBps);
        accrueInterest();
        baseRateBps = _baseRateBps;
        kinkUtilizationBps = _kinkUtilizationBps;
        kinkRateBps = _kinkRateBps;
        maxRateBps = _maxRateBps;
        emit RateParamsUpdated(_baseRateBps, _kinkUtilizationBps, _kinkRateBps, _maxRateBps);
    }

    function setPoolStatus(PoolStatus _status) external onlyOwner {
        if (uint8(_status) <= uint8(status)) revert InvalidStatusTransition();
        emit PoolStatusUpdated(status, _status);
        status = _status;
    }

    // ── Internal ────────────────────────────────────────────────────────

    /// @dev Convert borrow assets to shares. Rounds UP (favors protocol on borrow).
    function _borrowSharesToMint(uint256 assets) internal view returns (uint256) {
        if (totalBorrowShares == 0 || totalBorrowAssets == 0) {
            return assets; // 1:1 when pool is empty
        }
        return (assets * totalBorrowShares + totalBorrowAssets - 1) / totalBorrowAssets;
    }

    /// @dev Convert borrow shares to assets (debt). Rounds UP (favors protocol on repay).
    function _borrowAssetsOwed(uint256 shares) internal view returns (uint256) {
        if (totalBorrowShares == 0) return 0;
        return (shares * totalBorrowAssets + totalBorrowShares - 1) / totalBorrowShares;
    }

    function _pendingInterest() internal view returns (uint256) {
        return _pendingInterestAtRate(borrowRate());
    }

    function _pendingInterestAtRate(uint256 rate) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        if (elapsed == 0 || totalBorrowAssets == 0) return 0;
        return (totalBorrowAssets * rate * elapsed) / (BPS * SECONDS_PER_YEAR);
    }

    function _utilizationWithBorrowAssets(uint256 borrowAssets) internal view returns (uint256) {
        uint256 total = usdc.balanceOf(address(this)) + borrowAssets;
        if (total == 0) return 0;
        return (borrowAssets * BPS) / total;
    }

    function _borrowRateAtUtilization(uint256 util) internal view returns (uint256) {
        if (util <= kinkUtilizationBps) {
            // Below kink: linear from baseRate to kinkRate
            if (kinkUtilizationBps == 0) return baseRateBps;
            return baseRateBps + ((kinkRateBps - baseRateBps) * util) / kinkUtilizationBps;
        }

        // Above kink: linear from kinkRate to maxRate
        uint256 excessUtil = util - kinkUtilizationBps;
        uint256 excessRange = BPS - kinkUtilizationBps;
        if (excessRange == 0) return maxRateBps;
        return kinkRateBps + ((maxRateBps - kinkRateBps) * excessUtil) / excessRange;
    }

    function _validateRateParams(
        uint256 _baseRateBps,
        uint256 _kinkUtilizationBps,
        uint256 _kinkRateBps,
        uint256 _maxRateBps
    ) internal pure {
        if (_baseRateBps > _kinkRateBps) revert InvalidRateParams();
        if (_kinkRateBps > _maxRateBps) revert InvalidRateParams();
        if (_kinkUtilizationBps == 0 || _kinkUtilizationBps > BPS) revert InvalidRateParams();
        if (_maxRateBps > BPS) revert InvalidRateParams(); // cap at 100% APR
    }
}
