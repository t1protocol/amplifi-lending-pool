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

    IERC20 public immutable usdc;

    address public teeOperator;
    PoolStatus public status;
    uint256 public totalBorrowAssets;
    uint256 public totalBorrowShares;
    uint256 public lastAccrualTimestamp;

    mapping(uint256 loanId => uint256 shares) public loanShares;
    mapping(uint256 loanId => address wallet) public loanWallet;
    mapping(uint256 loanId => uint256 principal) public loanPrincipal;

    uint256 public feeBps;
    address public feeRecipient;
    uint256 public protocolFeesAccrued;

    uint256 public baseRateBps;
    uint256 public kinkUtilizationBps;
    uint256 public kinkRateBps;
    uint256 public maxRateBps;

    bool public borrowAllowlistEnabled;
    mapping(address wallet => bool allowed) public allowedBorrowerWallet;

    uint256 public maxBorrowPerLoan;
    uint256 public maxBorrowPerWindow;
    uint256 public borrowWindow;
    uint256 public windowStart;
    uint256 public windowBorrowed;

    uint256 public totalBadDebtRealized;

    uint256 private constant BPS = 10_000;
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant MAX_RATE_CAP_BPS = 1_000_000;
    uint256 public constant MAX_FEE_BPS = 5_000;
    // Virtual offset against the ERC-4626 first-depositor inflation attack.
    // https://docs.openzeppelin.com/contracts/5.x/erc4626#defending_with_a_virtual_offset
    uint256 private constant VIRTUAL_SHARES = 1e3;
    uint256 private constant VIRTUAL_ASSETS = 1e3;

    event Borrow(uint256 indexed loanId, address indexed wallet, uint256 amount, uint256 shares);
    event Repay(uint256 indexed loanId, address indexed wallet, uint256 repaid, uint256 shares);
    event BadDebtRealized(uint256 indexed loanId, uint256 badDebt);
    event InterestAccrued(uint256 interest, uint256 newTotalBorrowAssets);
    event TeeOperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event RateParamsUpdated(uint256 baseRateBps, uint256 kinkUtilizationBps, uint256 kinkRateBps, uint256 maxRateBps);
    event PoolStatusUpdated(PoolStatus oldStatus, PoolStatus newStatus);
    event BorrowAllowlistEnabledUpdated(bool enabled);
    event AllowedBorrowerWalletUpdated(address indexed wallet, bool allowed);
    event BorrowCapsUpdated(uint256 maxBorrowPerLoan, uint256 maxBorrowPerWindow, uint256 borrowWindow);
    event ProtocolFeeUpdated(uint256 feeBps);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event ProtocolFeeAccrued(uint256 indexed loanId, uint256 interest, uint256 fee);
    event ProtocolFeesCollected(address indexed to, uint256 amount);

    error OnlyTeeOperator();
    error OnlyBorrowerWallet();
    error PoolNotActive();
    error InsufficientLiquidity();
    error ZeroAmount();
    error ZeroShares();
    error InvalidRateParams();
    error InvalidStatusTransition();
    error ZeroAddress();
    error LoanAlreadyExists();
    error LoanNotFound();
    error WalletNotAllowed();
    error BorrowCapExceeded();
    error InvalidBorrowCaps();
    error InvalidFeeParams();
    error OnlyOwnerOrFeeRecipient();
    error FeeExceedsAccrued();

    modifier onlyTeeOperator() {
        if (msg.sender != teeOperator) revert OnlyTeeOperator();
        _;
    }

    modifier whenActive() {
        if (status != PoolStatus.Active) revert PoolNotActive();
        _;
    }

    constructor(
        address _usdc,
        address _owner,
        address _teeOperator,
        uint256 _baseRateBps,
        uint256 _kinkUtilizationBps,
        uint256 _kinkRateBps,
        uint256 _maxRateBps
    ) ERC20("Amplifi pUSD Lending Share", "apUSD") Ownable(_owner) {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_teeOperator == address(0)) revert ZeroAddress();
        usdc = IERC20(_usdc);
        teeOperator = _teeOperator;
        baseRateBps = _baseRateBps;
        kinkUtilizationBps = _kinkUtilizationBps;
        kinkRateBps = _kinkRateBps;
        maxRateBps = _maxRateBps;
        lastAccrualTimestamp = block.timestamp;

        _validateRateParams(_baseRateBps, _kinkUtilizationBps, _kinkRateBps, _maxRateBps);
    }

    function decimals() public pure override(ERC20, IERC20Metadata) returns (uint8) {
        return 6;
    }

    function asset() external view returns (address) {
        return address(usdc);
    }

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

    // Withdraw / redeem / repay are intentionally NOT gated by PoolStatus: gating them would let
    // setPoolStatus(Closed) permanently strand lender funds and outstanding loans (audit #1, #6).

    /// @notice Takes SHARES, not assets. This is NOT ERC-4626 withdraw(assets); for an asset
    ///         amount use withdrawAssets(assets) or withdraw(assets, receiver, owner).
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

    function withdraw(uint256 assets, address receiver, address _owner) external nonReentrant returns (uint256 shares) {
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

    function redeem(uint256 shares, address receiver, address _owner) external nonReentrant returns (uint256 assets) {
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

    function borrow(uint256 loanId, uint256 amount, address wallet) external nonReentrant onlyTeeOperator whenActive {
        if (amount == 0) revert ZeroAmount();
        if (wallet == address(0)) revert ZeroAddress();
        if (loanShares[loanId] != 0) revert LoanAlreadyExists();

        _enforceBorrowControls(wallet, amount);

        accrueInterest();

        if (amount > availableLiquidity()) revert InsufficientLiquidity();

        uint256 shares = _borrowSharesToMint(amount);
        loanShares[loanId] = shares;
        loanWallet[loanId] = wallet;
        loanPrincipal[loanId] = amount;
        totalBorrowShares += shares;
        totalBorrowAssets += amount;

        usdc.safeTransfer(wallet, amount);

        emit Borrow(loanId, wallet, amount, shares);
    }

    /// @notice Push-based: the loan's wallet must transfer the repayment to this pool in the same
    ///         atomic batch, immediately before calling this. There is no transferFrom (the deposit
    ///         wallets cannot approve a non-Polymarket spender), so the pushed funds are already in
    ///         balance and repay only settles the bookkeeping. Gated to loanWallet[loanId].
    /// @param amount Credited min(amount, debt); any shortfall is written off as bad debt (absorbed
    ///        by lenders via share price). Excess over debt stays as pool liquidity.
    function repay(uint256 loanId, uint256 amount) external nonReentrant {
        uint256 shares = loanShares[loanId];
        if (shares == 0) revert LoanNotFound();
        address wallet = loanWallet[loanId];
        if (msg.sender != wallet) revert OnlyBorrowerWallet();

        accrueInterest();

        uint256 debt = _borrowAssetsOwed(shares);
        uint256 repaid = debt < amount ? debt : amount;
        uint256 badDebt = debt - repaid;
        uint256 principal = loanPrincipal[loanId];

        delete loanShares[loanId];
        delete loanWallet[loanId];
        delete loanPrincipal[loanId];
        totalBorrowShares -= shares;
        totalBorrowAssets -= debt;

        emit Repay(loanId, wallet, repaid, shares);
        if (badDebt > 0) {
            totalBadDebtRealized += badDebt;
            emit BadDebtRealized(loanId, badDebt);
        } else if (feeBps > 0) {
            uint256 interest = debt > principal ? debt - principal : 0;
            uint256 fee = (interest * feeBps) / BPS;
            if (fee > 0) {
                protocolFeesAccrued += fee;
                emit ProtocolFeeAccrued(loanId, interest, fee);
            }
        }
    }

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
        uint256 gross = usdc.balanceOf(address(this)) + totalBorrowAssets + _pendingInterest();
        return gross > protocolFeesAccrued ? gross - protocolFeesAccrued : 0;
    }

    function availableLiquidity() public view returns (uint256) {
        uint256 bal = usdc.balanceOf(address(this));
        return bal > protocolFeesAccrued ? bal - protocolFeesAccrued : 0;
    }

    function utilization() public view returns (uint256) {
        if (totalBorrowAssets == 0) return 0;

        // Two-step to avoid a borrowRate() <-> _pendingInterest() recursion.
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
        uint256 supplyAndVirtual = totalSupply() + VIRTUAL_SHARES; // round up, favors pool
        return (shares * (totalAssets() + VIRTUAL_ASSETS) + supplyAndVirtual - 1) / supplyAndVirtual;
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 totalAndVirtual = totalAssets() + VIRTUAL_ASSETS; // round up, favors pool
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

    function setTeeOperator(address _teeOperator) external onlyOwner {
        if (_teeOperator == address(0)) revert ZeroAddress();
        emit TeeOperatorUpdated(teeOperator, _teeOperator);
        teeOperator = _teeOperator;
    }

    function setRateParams(uint256 _baseRateBps, uint256 _kinkUtilizationBps, uint256 _kinkRateBps, uint256 _maxRateBps)
        external
        virtual
        onlyOwner
    {
        _setRateParams(_baseRateBps, _kinkUtilizationBps, _kinkRateBps, _maxRateBps);
    }

    // internal so a subclass can gate the external entrypoint differently (e.g. a rate admin).
    function _setRateParams(
        uint256 _baseRateBps,
        uint256 _kinkUtilizationBps,
        uint256 _kinkRateBps,
        uint256 _maxRateBps
    ) internal virtual {
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

    function setBorrowAllowlistEnabled(bool enabled) external onlyOwner {
        borrowAllowlistEnabled = enabled;
        emit BorrowAllowlistEnabledUpdated(enabled);
    }

    function setAllowedBorrowerWallet(address wallet, bool allowed) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        allowedBorrowerWallet[wallet] = allowed;
        emit AllowedBorrowerWalletUpdated(wallet, allowed);
    }

    function setAllowedBorrowerWallets(address[] calldata wallets, bool allowed) external onlyOwner {
        uint256 len = wallets.length;
        for (uint256 i; i < len; ++i) {
            if (wallets[i] == address(0)) revert ZeroAddress();
            allowedBorrowerWallet[wallets[i]] = allowed;
            emit AllowedBorrowerWalletUpdated(wallets[i], allowed);
        }
    }

    /// @notice Any cap set to 0 disables that check. Reverts if a window cap is set with no window.
    function setBorrowCaps(uint256 _maxBorrowPerLoan, uint256 _maxBorrowPerWindow, uint256 _borrowWindow)
        external
        onlyOwner
    {
        if (_maxBorrowPerWindow != 0 && _borrowWindow == 0) revert InvalidBorrowCaps();
        maxBorrowPerLoan = _maxBorrowPerLoan;
        maxBorrowPerWindow = _maxBorrowPerWindow;
        borrowWindow = _borrowWindow;
        windowStart = block.timestamp;
        windowBorrowed = 0;
        emit BorrowCapsUpdated(_maxBorrowPerLoan, _maxBorrowPerWindow, _borrowWindow);
    }

    function setProtocolFee(uint256 _feeBps) external onlyOwner {
        _setProtocolFee(_feeBps);
    }

    // internal so a subclass can set the fee in its constructor (where onlyOwner would revert).
    function _setProtocolFee(uint256 _feeBps) internal {
        if (_feeBps > MAX_FEE_BPS) revert InvalidFeeParams();
        feeBps = _feeBps;
        emit ProtocolFeeUpdated(_feeBps);
    }

    /// @notice address(0) means only the owner can collect.
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        emit FeeRecipientUpdated(feeRecipient, _feeRecipient);
        feeRecipient = _feeRecipient;
    }

    function collectProtocolFees(address to, uint256 amount) external nonReentrant {
        if (msg.sender != owner() && msg.sender != feeRecipient) revert OnlyOwnerOrFeeRecipient();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > protocolFeesAccrued) revert FeeExceedsAccrued();
        protocolFeesAccrued -= amount;
        usdc.safeTransfer(to, amount);
        emit ProtocolFeesCollected(to, amount);
    }

    function _enforceBorrowControls(address wallet, uint256 amount) internal {
        if (borrowAllowlistEnabled && !allowedBorrowerWallet[wallet]) revert WalletNotAllowed();
        if (maxBorrowPerLoan != 0 && amount > maxBorrowPerLoan) revert BorrowCapExceeded();
        if (maxBorrowPerWindow != 0) {
            if (block.timestamp >= windowStart + borrowWindow) {
                windowStart = block.timestamp;
                windowBorrowed = 0;
            }
            if (windowBorrowed + amount > maxBorrowPerWindow) revert BorrowCapExceeded();
            windowBorrowed += amount;
        }
    }

    // rounds up, favors the protocol
    function _borrowSharesToMint(uint256 assets) internal view returns (uint256) {
        if (totalBorrowShares == 0 || totalBorrowAssets == 0) {
            return assets;
        }
        return (assets * totalBorrowShares + totalBorrowAssets - 1) / totalBorrowAssets;
    }

    // rounds up, favors the protocol
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
            if (kinkUtilizationBps == 0) return baseRateBps;
            return baseRateBps + ((kinkRateBps - baseRateBps) * util) / kinkUtilizationBps;
        }

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
