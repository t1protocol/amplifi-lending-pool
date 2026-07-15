// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {RateAdminLendingPool} from "../src/RateAdminLendingPool.sol";

/// @notice Deploys RateAdminLendingPool, the AmplifiLendingPool variant with a delegated
///         `rateAdmin` role. Same env-var interface as Deploy.s.sol, plus RATE_ADMIN_ADDRESS.
contract DeployRateAdmin is Script {
    // Polygon mainnet defaults. Override via env for other chains (e.g. Injective EVM).
    address constant DEFAULT_UNDERLYING = 0xC011a7E12a19f7B1f670d46F03B03f3342E82DFB; // pUSD
    address constant DEFAULT_TEE_OPERATOR = 0xAA270BeAC402474A3eDF164C51CdAD9597f01707;

    // Standardized rate model: 20% base / 200% kink / 1000% max at 85% utilization.
    uint256 constant DEFAULT_BASE_RATE_BPS = 2_000;
    uint256 constant DEFAULT_KINK_UTILIZATION_BPS = 8_500;
    uint256 constant DEFAULT_KINK_RATE_BPS = 20_000;
    uint256 constant DEFAULT_MAX_RATE_BPS = 100_000;

    // Protocol fee: 10% of interest on fully repaid loans.
    uint256 constant DEFAULT_FEE_BPS = 1_000;

    function run() external {
        address underlying = vm.envOr("UNDERLYING_ADDRESS", DEFAULT_UNDERLYING);
        address owner = vm.envAddress("OWNER_ADDRESS");
        address teeOperator = vm.envOr("TEE_OPERATOR_ADDRESS", DEFAULT_TEE_OPERATOR);
        // Optional: address(0) deploys with the role unset; assign later via setRateAdmin().
        address rateAdmin = vm.envOr("RATE_ADMIN_ADDRESS", address(0));

        uint256 baseRateBps = vm.envOr("BASE_RATE_BPS", DEFAULT_BASE_RATE_BPS);
        uint256 kinkUtilizationBps = vm.envOr("KINK_UTILIZATION_BPS", DEFAULT_KINK_UTILIZATION_BPS);
        uint256 kinkRateBps = vm.envOr("KINK_RATE_BPS", DEFAULT_KINK_RATE_BPS);
        uint256 maxRateBps = vm.envOr("MAX_RATE_BPS", DEFAULT_MAX_RATE_BPS);

        uint256 feeBps = vm.envOr("FEE_BPS", DEFAULT_FEE_BPS);
        // Optional: address(0) means only the owner can collect fees; set a treasury later.
        address feeRecipient = vm.envOr("FEE_RECIPIENT", address(0));

        console2.log("=== RateAdminLendingPool deploy ===");
        console2.log("Underlying:        ", underlying);
        console2.log("Owner:             ", owner);
        console2.log("TEE operator:      ", teeOperator);
        console2.log("Rate admin:        ", rateAdmin);
        console2.log("Base rate bps:     ", baseRateBps);
        console2.log("Kink util bps:     ", kinkUtilizationBps);
        console2.log("Kink rate bps:     ", kinkRateBps);
        console2.log("Max rate bps:      ", maxRateBps);
        console2.log("Fee bps:           ", feeBps);
        console2.log("Fee recipient:     ", feeRecipient);
        if (rateAdmin == address(0)) {
            console2.log("NOTE: rate admin is UNSET; assign it post-deploy with setRateAdmin().");
        }
        if (feeRecipient == address(0)) {
            console2.log("NOTE: fee recipient is UNSET; only the owner can collect fees.");
        }

        vm.startBroadcast();
        RateAdminLendingPool pool = new RateAdminLendingPool(
            underlying,
            owner,
            teeOperator,
            baseRateBps,
            kinkUtilizationBps,
            kinkRateBps,
            maxRateBps,
            rateAdmin,
            feeBps,
            feeRecipient
        );
        vm.stopBroadcast();

        console2.log("Deployed at:", address(pool));
        console2.log("Next: transferOwnership to the final owner, then have them call acceptOwnership().");
    }
}
