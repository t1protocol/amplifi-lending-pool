// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AmplifiLendingPool} from "./AmplifiLendingPool.sol";

// AmplifiLendingPool with a scoped rateAdmin that can call ONLY setRateParams. The owner
// appoints/rotates/revokes it and keeps every other privilege, including setting rate params.
contract RateAdminLendingPool is AmplifiLendingPool {
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
        rateAdmin = _rateAdmin;
        // Set at construction: the owner is a colder key than the deployer, so the owner-gated
        // setters may not be callable right after deploy.
        _setProtocolFee(_feeBps);
        feeRecipient = _feeRecipient;
        if (_feeRecipient != address(0)) emit FeeRecipientUpdated(address(0), _feeRecipient);
    }

    /// @notice address(0) revokes the role; the owner can always set rate params regardless.
    function setRateAdmin(address _rateAdmin) external onlyOwner {
        emit RateAdminUpdated(rateAdmin, _rateAdmin);
        rateAdmin = _rateAdmin;
    }

    function setRateParams(uint256 _baseRateBps, uint256 _kinkUtilizationBps, uint256 _kinkRateBps, uint256 _maxRateBps)
        external
        override
    {
        if (msg.sender != owner() && msg.sender != rateAdmin) revert OnlyOwnerOrRateAdmin();
        _setRateParams(_baseRateBps, _kinkUtilizationBps, _kinkRateBps, _maxRateBps);
    }
}
