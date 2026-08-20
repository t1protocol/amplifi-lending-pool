// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CollateralEscrow} from "../src/CollateralEscrow.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CollateralEscrowTest is Test {
    CollateralEscrow escrow;
    MockUSDC usdc;

    address owner = makeAddr("owner");
    address seizureRecipient = makeAddr("seizureRecipient");
    address relayer = makeAddr("relayer");
    address depositor;
    uint256 depositorKey;
    address attester;
    uint256 attesterKey;
    address seizer;
    uint256 seizerKey;

    // Fixture pins from tests/fixtures/collateral-escrow-vectors.json (amplifi repo).
    bytes32 constant FIXTURE_RELEASE_TYPEHASH = 0xb5c941473b37fdf1f7fff5174464d2a29eefc0abaec9f30c55dfa356d95bc25f;
    bytes32 constant FIXTURE_SEIZURE_TYPEHASH = 0xe5fd0c81556c04ea6f3492da83362fa13f90c119b6771dcd3a3dcb761a638901;
    bytes32 constant FIXTURE_DOMAIN_SEPARATOR = 0x5c0467ce52fb713f89440a93141120d44e8366c7971a614b4fc4378ff30abfdd;
    bytes32 constant FIXTURE_RELEASE_STRUCT_HASH = 0x87458ba6dee17e41d08f8a4e297c9deb8aad9469cea628e6343098de23f9c1fa;
    bytes32 constant FIXTURE_RELEASE_DIGEST = 0x620b29ab06f41352bef9f72ff8a559f97840202b16a4e8311c6dcae80de5d261;
    bytes32 constant FIXTURE_SEIZURE_STRUCT_HASH = 0x5a86014e79bed872caace43abf7e6f093a842de78e66c4721650e2a877e7ccf5;
    bytes32 constant FIXTURE_SEIZURE_DIGEST = 0x62d135222527320dd9c1a60de8dbb5b67253751976af034053942d0383093f23;
    address constant FIXTURE_VERIFYING_CONTRACT = 0x1111111111111111111111111111111111111111;
    address constant FIXTURE_SIGNER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant FIXTURE_ACCOUNT = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant FIXTURE_TOKEN = 0x2222222222222222222222222222222222222222;
    address constant FIXTURE_RECIPIENT = 0x3333333333333333333333333333333333333333;
    bytes constant FIXTURE_RELEASE_SIG =
        hex"dc94870e4b9a07cdf945d4f20c73fdcc9b44fc61ad77863261194bdf07bce2203fbb5a9ae446e8594ae5553bf87d8e635a6981ab6f3cb4ca66e3daff323e04d51c";
    bytes constant FIXTURE_SEIZURE_SIG =
        hex"49c9dc4eee413058315d49cd605419e35dfe7142ec53d2a9ba0264eb212f614e3c8a78cbb011dc3af50c57416f5d6385a3e44c3575891e014ef59af360420ff01c";

    uint256 constant BASE_TIME = 1_760_000_000;

    function setUp() public {
        (depositor, depositorKey) = makeAddrAndKey("depositor");
        (attester, attesterKey) = makeAddrAndKey("attester");
        (seizer, seizerKey) = makeAddrAndKey("seizer");

        vm.warp(BASE_TIME);
        usdc = new MockUSDC();
        escrow = new CollateralEscrow(owner);

        vm.startPrank(owner);
        escrow.setAttester(attester, true);
        escrow.setSeizer(seizer, true);
        escrow.setCollateralAllowed(address(usdc), true);
        escrow.setSeizureRecipient(seizureRecipient, true);
        vm.stopPrank();
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    function _deposit(address account, uint256 amount) internal {
        usdc.mint(account, amount);
        vm.startPrank(account);
        usdc.approve(address(escrow), amount);
        escrow.deposit(address(usdc), amount);
        vm.stopPrank();
    }

    function _release(address account, uint256 amount, uint256 attestationId, uint256 deadline)
        internal
        pure
        returns (CollateralEscrow.CollateralRelease memory)
    {
        return CollateralEscrow.CollateralRelease({
            account: account, token: FIXTURE_TOKEN, amount: amount, attestationId: attestationId, deadline: deadline
        });
    }

    function _escrowDomainSeparator() internal view returns (bytes32) {
        return _domainSeparator(block.chainid, address(escrow));
    }

    function _domainSeparator(uint256 chainId, address verifyingContract) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Amplifi")),
                keccak256(bytes("1")),
                chainId,
                verifyingContract
            )
        );
    }

    function _releaseStructHash(CollateralEscrow.CollateralRelease memory r) internal view returns (bytes32) {
        return keccak256(
            abi.encode(escrow.COLLATERAL_RELEASE_TYPEHASH(), r.account, r.token, r.amount, r.attestationId, r.deadline)
        );
    }

    function _signRelease(uint256 key, CollateralEscrow.CollateralRelease memory r)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = MessageHashUtils.toTypedDataHash(_escrowDomainSeparator(), _releaseStructHash(r));
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(rr, s, v);
    }

    function _releaseFor(address account, uint256 amount, uint256 attestationId)
        internal
        view
        returns (CollateralEscrow.CollateralRelease memory r, bytes memory sig)
    {
        r = CollateralEscrow.CollateralRelease({
            account: account,
            token: address(usdc),
            amount: amount,
            attestationId: attestationId,
            deadline: block.timestamp + 7 days
        });
        sig = _signRelease(attesterKey, r);
    }

    function _seizure(uint256 amount, uint256 attestationId)
        internal
        view
        returns (CollateralEscrow.CollateralSeizure memory)
    {
        return CollateralEscrow.CollateralSeizure({
            account: depositor,
            token: address(usdc),
            amount: amount,
            recipient: seizureRecipient,
            attestationId: attestationId,
            deadline: block.timestamp + 7 days
        });
    }

    // ── Vector reproduction (fixture domain: chainId 31337, verifyingContract 0x1111…1111) ──

    function test_vectors_typehashesMatchFixture() public view {
        assertEq(escrow.COLLATERAL_RELEASE_TYPEHASH(), FIXTURE_RELEASE_TYPEHASH);
        assertEq(escrow.COLLATERAL_SEIZURE_TYPEHASH(), FIXTURE_SEIZURE_TYPEHASH);
    }

    function test_vectors_domainSeparatorMatchesFixture() public {
        vm.chainId(31337);
        assertEq(_domainSeparator(31337, FIXTURE_VERIFYING_CONTRACT), FIXTURE_DOMAIN_SEPARATOR);
    }

    function test_vectors_releaseDigestAndSignerMatchFixture() public {
        vm.chainId(31337);
        CollateralEscrow.CollateralRelease memory r = _release(FIXTURE_ACCOUNT, 1_000_000, 42, 1_767_225_600);
        bytes32 structHash = _releaseStructHash(r);
        assertEq(structHash, FIXTURE_RELEASE_STRUCT_HASH);
        bytes32 digest =
            MessageHashUtils.toTypedDataHash(_domainSeparator(31337, FIXTURE_VERIFYING_CONTRACT), structHash);
        assertEq(digest, FIXTURE_RELEASE_DIGEST);
        assertEq(ECDSA.recover(digest, FIXTURE_RELEASE_SIG), FIXTURE_SIGNER);
    }

    function test_vectors_seizureDigestAndSignerMatchFixture() public {
        vm.chainId(31337);
        bytes32 structHash = keccak256(
            abi.encode(
                escrow.COLLATERAL_SEIZURE_TYPEHASH(),
                FIXTURE_ACCOUNT,
                FIXTURE_TOKEN,
                uint256(1_000_000),
                FIXTURE_RECIPIENT,
                uint256(43),
                uint256(1_767_225_600)
            )
        );
        assertEq(structHash, FIXTURE_SEIZURE_STRUCT_HASH);
        bytes32 digest =
            MessageHashUtils.toTypedDataHash(_domainSeparator(31337, FIXTURE_VERIFYING_CONTRACT), structHash);
        assertEq(digest, FIXTURE_SEIZURE_DIGEST);
        assertEq(ECDSA.recover(digest, FIXTURE_SEIZURE_SIG), FIXTURE_SIGNER);
    }

    // ── Deposit ───────────────────────────────────────────────────────────

    function test_deposit_creditsBalanceAndEmits() public {
        usdc.mint(depositor, 5_000_000);
        vm.startPrank(depositor);
        usdc.approve(address(escrow), 5_000_000);
        vm.expectEmit(true, true, false, true);
        emit CollateralEscrow.CollateralDeposited(depositor, address(usdc), 5_000_000);
        escrow.deposit(address(usdc), 5_000_000);
        vm.stopPrank();

        assertEq(escrow.balances(depositor, address(usdc)), 5_000_000);
        assertEq(usdc.balanceOf(address(escrow)), 5_000_000);
    }

    function test_deposit_nonAllowlistedTokenReverts() public {
        MockUSDC other = new MockUSDC();
        other.mint(depositor, 1_000_000);
        vm.startPrank(depositor);
        other.approve(address(escrow), 1_000_000);
        vm.expectRevert(abi.encodeWithSignature("TokenNotAllowed()"));
        escrow.deposit(address(other), 1_000_000);
        vm.stopPrank();
    }

    function test_deposit_zeroAmountReverts() public {
        vm.prank(depositor);
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        escrow.deposit(address(usdc), 0);
    }

    function test_deposit_pausedReverts() public {
        vm.prank(owner);
        escrow.pause();
        vm.prank(depositor);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        escrow.deposit(address(usdc), 1_000_000);
    }

    // ── withdrawWithAttestation end-to-end ────────────────────────────────

    function test_withdrawWithAttestation_paysAccount() public {
        _deposit(depositor, 5_000_000);
        (CollateralEscrow.CollateralRelease memory r, bytes memory sig) = _releaseFor(depositor, 2_000_000, 1);

        vm.prank(relayer);
        escrow.withdrawWithAttestation(r, sig);

        assertEq(usdc.balanceOf(depositor), 2_000_000);
        assertEq(escrow.balances(depositor, address(usdc)), 3_000_000);
        assertTrue(escrow.consumed(1));
    }

    function test_withdrawWithAttestation_replayReverts() public {
        _deposit(depositor, 5_000_000);
        (CollateralEscrow.CollateralRelease memory r, bytes memory sig) = _releaseFor(depositor, 1_000_000, 2);

        escrow.withdrawWithAttestation(r, sig);
        vm.expectRevert(abi.encodeWithSignature("AttestationConsumed()"));
        escrow.withdrawWithAttestation(r, sig);
    }

    function test_withdrawWithAttestation_expiredReverts() public {
        _deposit(depositor, 5_000_000);
        (CollateralEscrow.CollateralRelease memory r, bytes memory sig) = _releaseFor(depositor, 1_000_000, 3);

        vm.warp(r.deadline + 1);
        vm.expectRevert(abi.encodeWithSignature("AttestationExpired()"));
        escrow.withdrawWithAttestation(r, sig);
    }

    function test_withdrawWithAttestation_deadlineBeyondMaxTtlReverts() public {
        _deposit(depositor, 5_000_000);
        CollateralEscrow.CollateralRelease memory r = CollateralEscrow.CollateralRelease({
            account: depositor,
            token: address(usdc),
            amount: 1_000_000,
            attestationId: 4,
            deadline: block.timestamp + 30 days + 1
        });
        bytes memory sig = _signRelease(attesterKey, r);

        vm.expectRevert(abi.encodeWithSignature("DeadlineTooFar()"));
        escrow.withdrawWithAttestation(r, sig);
    }

    function test_withdrawWithAttestation_wrongSignerReverts() public {
        _deposit(depositor, 5_000_000);
        (CollateralEscrow.CollateralRelease memory r,) = _releaseFor(depositor, 1_000_000, 5);
        bytes memory sig = _signRelease(depositorKey, r);

        vm.expectRevert(abi.encodeWithSignature("InvalidAttester()"));
        escrow.withdrawWithAttestation(r, sig);
    }

    function test_withdrawWithAttestation_zeroAmountReverts() public {
        (CollateralEscrow.CollateralRelease memory r, bytes memory sig) = _releaseFor(depositor, 0, 6);
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        escrow.withdrawWithAttestation(r, sig);
    }

    function test_withdrawWithAttestation_pausedReverts() public {
        _deposit(depositor, 5_000_000);
        (CollateralEscrow.CollateralRelease memory r, bytes memory sig) = _releaseFor(depositor, 1_000_000, 7);

        vm.prank(owner);
        escrow.pause();
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        escrow.withdrawWithAttestation(r, sig);
    }

    // ── Cushion semantics ─────────────────────────────────────────────────

    function test_cushion_releaseCanExceedAccountBalance() public {
        _deposit(depositor, 1_000_000);
        usdc.mint(relayer, 3_000_000);
        vm.startPrank(relayer);
        usdc.approve(address(escrow), 3_000_000);
        vm.expectEmit(true, true, false, true);
        emit CollateralEscrow.CushionFunded(relayer, address(usdc), 3_000_000);
        escrow.fundCushion(address(usdc), 3_000_000);
        vm.stopPrank();

        // Release more than the depositor's own balance — profits paid from the cushion.
        (CollateralEscrow.CollateralRelease memory r, bytes memory sig) = _releaseFor(depositor, 2_500_000, 8);
        escrow.withdrawWithAttestation(r, sig);

        assertEq(usdc.balanceOf(depositor), 2_500_000);
        assertEq(escrow.balances(depositor, address(usdc)), 0); // clamped, not underflowed
        assertEq(usdc.balanceOf(address(escrow)), 1_500_000);
    }

    function test_cushion_underfundedContractReverts() public {
        _deposit(depositor, 1_000_000);
        (CollateralEscrow.CollateralRelease memory r, bytes memory sig) = _releaseFor(depositor, 2_000_000, 9);

        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)", address(escrow), 1_000_000, 2_000_000
            )
        );
        escrow.withdrawWithAttestation(r, sig);
    }

    // ── Seize ─────────────────────────────────────────────────────────────

    function test_seize_movesCollateralToAllowlistedRecipient() public {
        _deposit(depositor, 5_000_000);
        vm.prank(seizer);
        escrow.seize(_seizure(2_000_000, 10));

        assertEq(usdc.balanceOf(seizureRecipient), 2_000_000);
        assertEq(escrow.balances(depositor, address(usdc)), 3_000_000);
        assertTrue(escrow.consumed(10));
    }

    function test_seize_attesterCannotSeize() public {
        _deposit(depositor, 5_000_000);
        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSignature("OnlySeizer()"));
        escrow.seize(_seizure(1_000_000, 11));
    }

    function test_seize_seizerCannotAttest() public {
        _deposit(depositor, 5_000_000);
        (CollateralEscrow.CollateralRelease memory r,) = _releaseFor(depositor, 1_000_000, 12);
        bytes memory sig = _signRelease(seizerKey, r);

        vm.expectRevert(abi.encodeWithSignature("InvalidAttester()"));
        escrow.withdrawWithAttestation(r, sig);
    }

    function test_seize_nonAllowlistedRecipientReverts() public {
        _deposit(depositor, 5_000_000);
        CollateralEscrow.CollateralSeizure memory s = _seizure(1_000_000, 13);
        s.recipient = makeAddr("attacker");

        vm.prank(seizer);
        vm.expectRevert(abi.encodeWithSignature("RecipientNotAllowed()"));
        escrow.seize(s);
    }

    function test_seize_balanceClampsAtZero() public {
        _deposit(depositor, 1_000_000);
        usdc.mint(address(this), 2_000_000);
        usdc.approve(address(escrow), 2_000_000);
        escrow.fundCushion(address(usdc), 2_000_000);

        vm.prank(seizer);
        escrow.seize(_seizure(2_500_000, 14));
        assertEq(escrow.balances(depositor, address(usdc)), 0);
    }

    function test_seize_pausedReverts() public {
        _deposit(depositor, 5_000_000);
        vm.prank(owner);
        escrow.pause();
        vm.prank(seizer);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        escrow.seize(_seizure(1_000_000, 15));
    }

    function test_seize_consumedIdSharedAcrossReleaseAndSeize() public {
        _deposit(depositor, 5_000_000);

        // Release consumes id 20; a seizure reusing it must revert.
        (CollateralEscrow.CollateralRelease memory r, bytes memory sig) = _releaseFor(depositor, 1_000_000, 20);
        escrow.withdrawWithAttestation(r, sig);
        vm.prank(seizer);
        vm.expectRevert(abi.encodeWithSignature("AttestationConsumed()"));
        escrow.seize(_seizure(1_000_000, 20));

        // Seizure consumes id 21; a release reusing it must revert.
        vm.prank(seizer);
        escrow.seize(_seizure(1_000_000, 21));
        (CollateralEscrow.CollateralRelease memory r2, bytes memory sig2) = _releaseFor(depositor, 1_000_000, 21);
        vm.expectRevert(abi.encodeWithSignature("AttestationConsumed()"));
        escrow.withdrawWithAttestation(r2, sig2);
    }

    // ── cancelAttestation ─────────────────────────────────────────────────

    function test_cancelAttestation_marksConsumedWithoutTransfer() public {
        _deposit(depositor, 5_000_000);
        (CollateralEscrow.CollateralRelease memory r, bytes memory sig) = _releaseFor(depositor, 1_000_000, 30);

        vm.prank(attester);
        escrow.cancelAttestation(30);
        assertTrue(escrow.consumed(30));
        assertEq(usdc.balanceOf(address(escrow)), 5_000_000);

        vm.expectRevert(abi.encodeWithSignature("AttestationConsumed()"));
        escrow.withdrawWithAttestation(r, sig);
    }

    function test_cancelAttestation_nonAttesterReverts() public {
        vm.prank(seizer);
        vm.expectRevert(abi.encodeWithSignature("OnlyAttester()"));
        escrow.cancelAttestation(31);
    }

    // ── Caps ──────────────────────────────────────────────────────────────

    function test_caps_perAttestationCapEnforced() public {
        _deposit(depositor, 10_000_000);
        vm.prank(owner);
        escrow.setCaps(1_500_000, 0);

        (CollateralEscrow.CollateralRelease memory r, bytes memory sig) = _releaseFor(depositor, 2_000_000, 40);
        vm.expectRevert(abi.encodeWithSignature("PerAttestationCapExceeded()"));
        escrow.withdrawWithAttestation(r, sig);

        (CollateralEscrow.CollateralRelease memory r2, bytes memory sig2) = _releaseFor(depositor, 1_500_000, 41);
        escrow.withdrawWithAttestation(r2, sig2);
        assertEq(usdc.balanceOf(depositor), 1_500_000);
    }

    function test_caps_dailyLimitEnforcedThenResetsAfterADay() public {
        _deposit(depositor, 10_000_000);
        vm.prank(owner);
        escrow.setCaps(0, 3_000_000);

        (CollateralEscrow.CollateralRelease memory r, bytes memory sig) = _releaseFor(depositor, 3_000_000, 50);
        escrow.withdrawWithAttestation(r, sig);

        (CollateralEscrow.CollateralRelease memory r2, bytes memory sig2) = _releaseFor(depositor, 1_000_000, 51);
        vm.expectRevert(abi.encodeWithSignature("DailyReleaseLimitExceeded()"));
        escrow.withdrawWithAttestation(r2, sig2);

        vm.warp(block.timestamp + 1 days);
        (CollateralEscrow.CollateralRelease memory r3, bytes memory sig3) = _releaseFor(depositor, 1_000_000, 52);
        escrow.withdrawWithAttestation(r3, sig3);
        assertEq(usdc.balanceOf(depositor), 4_000_000);
    }

    // ── Owner admin ───────────────────────────────────────────────────────

    function test_admin_settersRevertForNonOwner() public {
        address attacker = makeAddr("nonOwner");
        bytes memory err = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker);

        vm.startPrank(attacker);
        vm.expectRevert(err);
        escrow.setAttester(attacker, true);
        vm.expectRevert(err);
        escrow.setSeizer(attacker, true);
        vm.expectRevert(err);
        escrow.setCollateralAllowed(address(usdc), false);
        vm.expectRevert(err);
        escrow.setSeizureRecipient(attacker, true);
        vm.expectRevert(err);
        escrow.setCaps(1, 1);
        vm.expectRevert(err);
        escrow.setMaxAttestationTtl(1 days);
        vm.expectRevert(err);
        escrow.pause();
        vm.expectRevert(err);
        escrow.unpause();
        vm.stopPrank();
    }

    function test_admin_zeroAddressReverts() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        escrow.setAttester(address(0), true);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        escrow.setSeizer(address(0), true);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        escrow.setCollateralAllowed(address(0), true);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        escrow.setSeizureRecipient(address(0), true);
        vm.expectRevert(abi.encodeWithSignature("ZeroTtl()"));
        escrow.setMaxAttestationTtl(0);
        vm.stopPrank();
    }

    function test_admin_setMaxAttestationTtlBoundsDeadline() public {
        _deposit(depositor, 5_000_000);
        vm.prank(owner);
        escrow.setMaxAttestationTtl(1 days);

        CollateralEscrow.CollateralRelease memory r = CollateralEscrow.CollateralRelease({
            account: depositor,
            token: address(usdc),
            amount: 1_000_000,
            attestationId: 60,
            deadline: block.timestamp + 2 days
        });
        bytes memory sig = _signRelease(attesterKey, r);
        vm.expectRevert(abi.encodeWithSignature("DeadlineTooFar()"));
        escrow.withdrawWithAttestation(r, sig);
    }

    function test_admin_ownable2StepTransfer() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        escrow.transferOwnership(newOwner);
        assertEq(escrow.owner(), owner);
        assertEq(escrow.pendingOwner(), newOwner);

        vm.prank(newOwner);
        escrow.acceptOwnership();
        assertEq(escrow.owner(), newOwner);
    }
}
