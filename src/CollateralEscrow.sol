// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title CollateralEscrow
/// @notice Holds user collateral released only against EIP-712 withdrawal attestations signed by
///         amplifi-controlled attester keys, with a separate seizer role for the shortfall path.
///         Spec: amplifi docs/collateral-escrow-attestation.md. Per-account balances are
///         informational accounting (clamped at zero, never a release ceiling): the contract may
///         hold a protocol-funded cushion (see fundCushion) so releases can exceed a user's own
///         deposit, e.g. trading profits.
contract CollateralEscrow is EIP712, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;

    // ── Structs ─────────────────────────────────────────────────────────
    struct CollateralRelease {
        address account;
        address token;
        uint256 amount;
        uint256 attestationId;
        uint256 deadline;
    }

    struct CollateralSeizure {
        address account;
        address token;
        uint256 amount;
        address recipient;
        uint256 attestationId;
        uint256 deadline;
    }

    // ── Constants ───────────────────────────────────────────────────────
    bytes32 public constant COLLATERAL_RELEASE_TYPEHASH = keccak256(
        "CollateralRelease(address account,address token,uint256 amount,uint256 attestationId,uint256 deadline)"
    );
    bytes32 public constant COLLATERAL_SEIZURE_TYPEHASH = keccak256(
        "CollateralSeizure(address account,address token,uint256 amount,address recipient,uint256 attestationId,uint256 deadline)"
    );

    // ── State ───────────────────────────────────────────────────────────
    mapping(address account => mapping(address token => uint256)) public balances;
    // Shared across release and seizure so amplifi allocates ids from one sequence.
    mapping(uint256 attestationId => bool) public consumed;
    mapping(address => bool) public isAttester;
    mapping(address => bool) public isSeizer;
    mapping(address token => bool) public isCollateralAllowed;
    mapping(address recipient => bool) public isSeizureRecipient;

    uint256 public maxAttestationTtl = 30 days;
    uint256 public perAttestationCap; // 0 = disabled
    uint256 public dailyReleaseLimit; // 0 = disabled
    uint256 public dayStart;
    uint256 public releasedInDay;

    // ── Events ──────────────────────────────────────────────────────────
    event CollateralDeposited(address indexed account, address indexed token, uint256 amount);
    event CollateralReleased(
        address indexed account, address indexed token, uint256 amount, uint256 indexed attestationId, address caller
    );
    event CollateralSeized(
        address indexed account,
        address indexed token,
        uint256 amount,
        address recipient,
        uint256 indexed attestationId,
        address caller
    );
    event CushionFunded(address indexed funder, address indexed token, uint256 amount);
    event AttestationCancelled(uint256 indexed attestationId, address indexed attester);
    event AttesterUpdated(address indexed attester, bool allowed);
    event SeizerUpdated(address indexed seizer, bool allowed);
    event CollateralAllowedUpdated(address indexed token, bool allowed);
    event SeizureRecipientUpdated(address indexed recipient, bool allowed);
    event CapsUpdated(uint256 perAttestationCap, uint256 dailyReleaseLimit);
    event MaxAttestationTtlUpdated(uint256 maxAttestationTtl);

    // ── Errors ──────────────────────────────────────────────────────────
    error ZeroAmount();
    error ZeroAddress();
    error TokenNotAllowed();
    error AttestationExpired();
    error DeadlineTooFar();
    error InvalidAttester();
    error AttestationConsumed();
    error OnlySeizer();
    error OnlyAttester();
    error RecipientNotAllowed();
    error PerAttestationCapExceeded();
    error DailyReleaseLimitExceeded();
    error ZeroTtl();

    constructor(address initialOwner) EIP712("Amplifi", "1") Ownable(initialOwner) {}

    // ── Deposits ────────────────────────────────────────────────────────

    /// @notice Deposit an allowlisted collateral token. Standard non-rebasing ERC-20s only:
    ///         the ledger assumes a transfer of `amount` credits exactly `amount`.
    function deposit(address token, uint256 amount) external whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (!isCollateralAllowed[token]) revert TokenNotAllowed();
        balances[msg.sender][token] += amount;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralDeposited(msg.sender, token, amount);
    }

    /// @notice Add token cushion held by the contract but credited to no account, so releases
    ///         (e.g. trading profits) can exceed a user's own deposit. Callable by anyone.
    function fundCushion(address token, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit CushionFunded(msg.sender, token, amount);
    }

    // ── Release (attestation-gated withdrawal) ──────────────────────────

    /// @notice Release collateral to `release.account` against an attester-signed EIP-712
    ///         CollateralRelease. msg.sender is deliberately unrestricted (anyone may relay);
    ///         funds only ever move to the attested account. The transfer draws on the
    ///         contract's whole holdings: the per-account balance is decremented clamped at
    ///         zero, and an underfunded contract reverts in the token transfer.
    function withdrawWithAttestation(CollateralRelease calldata release, bytes calldata signature)
        external
        whenNotPaused
    {
        if (release.amount == 0) revert ZeroAmount();
        if (block.timestamp > release.deadline) revert AttestationExpired();
        if (release.deadline > block.timestamp + maxAttestationTtl) revert DeadlineTooFar();
        if (perAttestationCap != 0 && release.amount > perAttestationCap) revert PerAttestationCapExceeded();

        bytes32 structHash = keccak256(
            abi.encode(
                COLLATERAL_RELEASE_TYPEHASH,
                release.account,
                release.token,
                release.amount,
                release.attestationId,
                release.deadline
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        if (!isAttester[signer]) revert InvalidAttester();

        if (consumed[release.attestationId]) revert AttestationConsumed();
        consumed[release.attestationId] = true;

        if (dailyReleaseLimit != 0) {
            if (block.timestamp >= dayStart + 1 days) {
                dayStart = block.timestamp;
                releasedInDay = 0;
            }
            if (releasedInDay + release.amount > dailyReleaseLimit) revert DailyReleaseLimitExceeded();
            releasedInDay += release.amount;
        }

        uint256 bal = balances[release.account][release.token];
        balances[release.account][release.token] = bal > release.amount ? bal - release.amount : 0;

        IERC20(release.token).safeTransfer(release.account, release.amount);
        emit CollateralReleased(release.account, release.token, release.amount, release.attestationId, msg.sender);
    }

    /// @notice Mark an attestation id consumed without transferring, so a corrected attestation
    ///         can be re-issued immediately (e.g. after a seizure strands a live one).
    function cancelAttestation(uint256 attestationId) external {
        if (!isAttester[msg.sender]) revert OnlyAttester();
        if (consumed[attestationId]) revert AttestationConsumed();
        consumed[attestationId] = true;
        emit AttestationCancelled(attestationId, msg.sender);
    }

    // ── Seizure (shortfall path) ────────────────────────────────────────

    /// @notice Move collateral to an allowlisted protocol recipient on a shortfall. Gated on a
    ///         seizer set kept separate from the attester set, so one leaked key never grants
    ///         both release and seizure authority. Shares the consumed-id mapping with release.
    function seize(CollateralSeizure calldata s) external whenNotPaused {
        if (!isSeizer[msg.sender]) revert OnlySeizer();
        if (s.amount == 0) revert ZeroAmount();
        if (!isSeizureRecipient[s.recipient]) revert RecipientNotAllowed();

        if (consumed[s.attestationId]) revert AttestationConsumed();
        consumed[s.attestationId] = true;

        uint256 bal = balances[s.account][s.token];
        balances[s.account][s.token] = bal > s.amount ? bal - s.amount : 0;

        IERC20(s.token).safeTransfer(s.recipient, s.amount);
        emit CollateralSeized(s.account, s.token, s.amount, s.recipient, s.attestationId, msg.sender);
    }

    // ── Owner admin ─────────────────────────────────────────────────────

    function setAttester(address attester, bool allowed) external onlyOwner {
        if (attester == address(0)) revert ZeroAddress();
        isAttester[attester] = allowed;
        emit AttesterUpdated(attester, allowed);
    }

    function setSeizer(address seizer, bool allowed) external onlyOwner {
        if (seizer == address(0)) revert ZeroAddress();
        isSeizer[seizer] = allowed;
        emit SeizerUpdated(seizer, allowed);
    }

    function setCollateralAllowed(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        isCollateralAllowed[token] = allowed;
        emit CollateralAllowedUpdated(token, allowed);
    }

    function setSeizureRecipient(address recipient, bool allowed) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        isSeizureRecipient[recipient] = allowed;
        emit SeizureRecipientUpdated(recipient, allowed);
    }

    /// @notice 0 disables the corresponding cap.
    function setCaps(uint256 perAttestation, uint256 dailyLimit) external onlyOwner {
        perAttestationCap = perAttestation;
        dailyReleaseLimit = dailyLimit;
        emit CapsUpdated(perAttestation, dailyLimit);
    }

    function setMaxAttestationTtl(uint256 ttl) external onlyOwner {
        if (ttl == 0) revert ZeroTtl();
        maxAttestationTtl = ttl;
        emit MaxAttestationTtlUpdated(ttl);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
