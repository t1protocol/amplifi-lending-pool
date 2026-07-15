// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AmplifiLendingPool} from "./AmplifiLendingPool.sol";

/// @title RateAdminLendingPool
/// @notice AmplifiLendingPool variant that delegates rate-model tuning to a scoped `rateAdmin`
///         role, so a partner can set their own rate params without holding owner power. The
///         owner appoints/rotates/revokes the rateAdmin and retains every other privilege
///         (teeOperator, pool status, borrow controls) plus the ability to set rate params.
///         The rateAdmin can ONLY call setRateParams. Nothing else.
contract RateAdminLendingPool is AmplifiLendingPool {
    /// @notice Address permitted to set rate params in addition to the owner. address(0) = unset.
    address public rateAdmin;

    event RateAdminUpdated(address indexed oldAdmin, address indexed newAdmin);

    error OnlyOwnerOrRateAdmin();

    constructor(
        address _usdc,
        address _owner,
        address _teeOperator,
        uint256 _baseRateBps,
        uint256 _kinkUtilizationBps,
        uint256 _kinkRateBps,
        uint256 _maxRateBps,
        address _rateAdmin,
        uint256 _feeBps,
        address _feeRecipient
    ) AmplifiLendingPool(_usdc, _owner, _teeOperator, _baseRateBps, _kinkUtilizationBps, _kinkRateBps, _maxRateBps) {
        // _rateAdmin == address(0) is allowed: the role starts unset and can be assigned later.
        rateAdmin = _rateAdmin;
        // Fee params are set here (not post-deploy) because the owner is a colder key than the
        // deployer, so the owner-gated setters may not be callable right after deploy.
        _setProtocolFee(_feeBps);
        feeRecipient = _feeRecipient;
        if (_feeRecipient != address(0)) emit FeeRecipientUpdated(address(0), _feeRecipient);
    }

    /// @notice Appoint, rotate, or revoke the rate admin. address(0) revokes the role; the owner
    ///         can always set rate params, so revocation cannot lock the pool out of rate updates.
    function setRateAdmin(address _rateAdmin) external onlyOwner {
        emit RateAdminUpdated(rateAdmin, _rateAdmin);
        rateAdmin = _rateAdmin;
    }

    /// @notice Set the interest-rate model params. Callable by the owner OR the rateAdmin.
    function setRateParams(uint256 _baseRateBps, uint256 _kinkUtilizationBps, uint256 _kinkRateBps, uint256 _maxRateBps)
        external
        override
    {
        if (msg.sender != owner() && msg.sender != rateAdmin) revert OnlyOwnerOrRateAdmin();
        _setRateParams(_baseRateBps, _kinkUtilizationBps, _kinkRateBps, _maxRateBps);
    }
}
