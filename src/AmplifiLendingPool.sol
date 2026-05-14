// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

enum PoolStatus {
    Active,
    WindingDown,
    Closed
}

contract AmplifiLendingPool is ERC20, IERC4626, ReentrancyGuard, Ownable2Step {
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
    mapping(uint256 loanId => uint256 shares) public loanShares;

    // ── Interest Rate Model ─────────────────────────────────────────────
    uint256 public baseRateBps;
    uint256 public kinkUtilizationBps;
    uint256 public kinkRateBps;
    uint256 public maxRateBps;

    // ── Constants ───────────────────────────────────────────────────────
    uint256 private constant BPS = 10_000;
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    // Hard ceiling on maxRateBps (10,000% APR). Prevents the rate-spike drain path
    // where an owner with one share inflates totalBorrowAssets, rounds withdraw share
    // cost down to 1, and burns 1 share for the whole pool.
    uint256 public constant MAX_RATE_CAP_BPS = 1_000_000;
    // Virtual offset to mitigate ERC-4626 first-depositor inflation attack.
    // See: https://docs.openzeppelin.com/contracts/5.x/erc4626#defending_with_a_virtual_offset
    uint256 private constant VIRTUAL_SHARES = 1e3;
    uint256 private constant VIRTUAL_ASSETS = 1e3;

    // ── Events ──────────────────────────────────────────────────────────
    // Deposit and Withdraw events are inherited from IERC4626 (with sender/owner/receiver).
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
    error InsufficientLiquidity();
    error ZeroAmount();
    error ZeroShares();
    error InvalidRateParams();
    error InvalidStatusTransition();
    error ZeroAddress();
    error LoanAlreadyExists();
    error LoanNotFound();
    error LoansOutstanding();

    // ── Modifiers ───────────────────────────────────────────────────────
    modifier onlyTeeOperator() {
        if (msg.sender != teeOperator) revert OnlyTeeOperator();
        _;
    }

    modifier whenActive() {
        if (status != PoolStatus.Active) revert PoolNotActive();
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

    // ── ERC20 / IERC20Metadata Override ─────────────────────────────────
    function decimals() public pure override(ERC20, IERC20Metadata) returns (uint8) {
        return 6;
    }

    // ── ERC-4626 ────────────────────────────────────────────────────────

    function asset() external view returns (address) {
        return address(usdc);
    }

    // ── Deposits ────────────────────────────────────────────────────────

    /// @notice 1-arg convenience wrapper. Mints shares to msg.sender.
    function deposit(uint256 assets) external returns (uint256 shares) {
        return deposit(assets, msg.sender);
    }

    function deposit(uint256 assets, address receiver) public nonReentrant whenActive returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        accrueInterest();

        shares = assetsToShares(assets);
        if (shares == 0) revert ZeroShares();

        usdc.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external nonReentrant whenActive returns (uint256 assets) {
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();
        accrueInterest();

        assets = previewMint(shares);
        if (assets == 0) revert ZeroAmount();

        usdc.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    // ── Withdrawals ─────────────────────────────────────────────────────
    // Withdraw / redeem / repay are NOT gated by PoolStatus.Closed. Gating them
    // would let a careless or malicious setPoolStatus(Closed) permanently strand
    // lender funds and outstanding loans (audit #1, #6).

    /// @notice 1-arg convenience wrapper. Burns shares from msg.sender, sends assets to msg.sender.
    function withdraw(uint256 shares) external nonReentrant returns (uint256 assets) {
        if (shares == 0) revert ZeroShares();
        accrueInterest();

        assets = sharesToAssets(shares);
        if (assets == 0) revert ZeroAmount();
        if (assets > availableLiquidity()) revert InsufficientLiquidity();

        _burn(msg.sender, shares);
        usdc.safeTransfer(msg.sender, assets);

        emit Withdraw(msg.sender, msg.sender, msg.sender, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address _owner)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        accrueInterest();

        if (assets > availableLiquidity()) revert InsufficientLiquidity();

        shares = previewWithdraw(assets);
        if (shares == 0) revert ZeroShares();

        if (_owner != msg.sender) {
            _spendAllowance(_owner, msg.sender, shares);
        }
        _burn(_owner, shares);
        usdc.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, _owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address _owner)
        external
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();
        accrueInterest();

        assets = sharesToAssets(shares);
        if (assets == 0) revert ZeroAmount();
        if (assets > availableLiquidity()) revert InsufficientLiquidity();

        if (_owner != msg.sender) {
            _spendAllowance(_owner, msg.sender, shares);
        }
        _burn(_owner, shares);
        usdc.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, _owner, assets, shares);
    }

    /// @notice Backward-compat. Takes assets, burns shares from msg.sender, sends to msg.sender.
    function withdrawAssets(uint256 assets) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        accrueInterest();

        if (assets > availableLiquidity()) revert InsufficientLiquidity();

        shares = previewWithdraw(assets);
        if (shares == 0) revert ZeroShares();

        _burn(msg.sender, shares);
        usdc.safeTransfer(msg.sender, assets);

        emit Withdraw(msg.sender, msg.sender, msg.sender, assets, shares);
    }

    // ── Borrow / Repay ──────────────────────────────────────────────────

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
    ///      USDC inflow. Lenders absorb the loss proportionally via reduced share price.
    function repay(uint256 loanId, uint256 maxRepay) external nonReentrant onlyTeeOperator {
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

    // ── ERC-4626 View Functions ──────────────────────────────────────────

    function maxDeposit(address) external view returns (uint256) {
        return status == PoolStatus.Active ? type(uint256).max : 0;
    }

    function maxMint(address) external view returns (uint256) {
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

    function previewMint(uint256 shares) public view returns (uint256) {
        // Round UP (favors pool): assets = ceil(shares * (totalAssets + VA) / (totalSupply + VS))
        uint256 supplyAndVirtual = totalSupply() + VIRTUAL_SHARES;
        return (shares * (totalAssets() + VIRTUAL_ASSETS) + supplyAndVirtual - 1) / supplyAndVirtual;
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        // Round UP (favors pool)
        uint256 totalAndVirtual = totalAssets() + VIRTUAL_ASSETS;
        return (assets * (totalSupply() + VIRTUAL_SHARES) + totalAndVirtual - 1) / totalAndVirtual;
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
        // Changing fundAccount while loans are outstanding breaks repay (which pulls
        // USDC from fundAccount via allowance set against the original address).
        if (totalBorrowShares > 0) revert LoansOutstanding();
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
        if (_maxRateBps > MAX_RATE_CAP_BPS) revert InvalidRateParams();
        if (_kinkUtilizationBps == 0 || _kinkUtilizationBps > BPS) revert InvalidRateParams();
    }
}
