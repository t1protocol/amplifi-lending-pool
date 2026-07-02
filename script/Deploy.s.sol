// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AmplifiLendingPool} from "../src/AmplifiLendingPool.sol";

contract Deploy is Script {
    // Polygon mainnet defaults
    address constant DEFAULT_UNDERLYING = 0xC011a7E12a19f7B1f670d46F03B03f3342E82DFB; // pUSD
    address constant DEFAULT_TEE_OPERATOR = 0xAA270BeAC402474A3eDF164C51CdAD9597f01707;

    // Standardized rate model: 20% base / 200% kink / 1000% max at 85% utilization.
    uint256 constant DEFAULT_BASE_RATE_BPS = 2_000;
    uint256 constant DEFAULT_KINK_UTILIZATION_BPS = 8_500;
    uint256 constant DEFAULT_KINK_RATE_BPS = 20_000;
    uint256 constant DEFAULT_MAX_RATE_BPS = 100_000;

    function run() external {
        address underlying = vm.envOr("UNDERLYING_ADDRESS", DEFAULT_UNDERLYING);
        address owner = vm.envAddress("OWNER_ADDRESS");
        address teeOperator = vm.envOr("TEE_OPERATOR_ADDRESS", DEFAULT_TEE_OPERATOR);

        uint256 baseRateBps = vm.envOr("BASE_RATE_BPS", DEFAULT_BASE_RATE_BPS);
        uint256 kinkUtilizationBps = vm.envOr("KINK_UTILIZATION_BPS", DEFAULT_KINK_UTILIZATION_BPS);
        uint256 kinkRateBps = vm.envOr("KINK_RATE_BPS", DEFAULT_KINK_RATE_BPS);
        uint256 maxRateBps = vm.envOr("MAX_RATE_BPS", DEFAULT_MAX_RATE_BPS);

        console2.log("=== AmplifiLendingPool deploy ===");
        console2.log("Underlying:        ", underlying);
        console2.log("Owner:             ", owner);
        console2.log("TEE operator:      ", teeOperator);
        console2.log("Base rate bps:     ", baseRateBps);
        console2.log("Kink util bps:     ", kinkUtilizationBps);
        console2.log("Kink rate bps:     ", kinkRateBps);
        console2.log("Max rate bps:      ", maxRateBps);

        vm.startBroadcast();
        AmplifiLendingPool pool = new AmplifiLendingPool(
            underlying, owner, teeOperator, baseRateBps, kinkUtilizationBps, kinkRateBps, maxRateBps
        );
        vm.stopBroadcast();

        console2.log("Deployed at:", address(pool));
        console2.log("Next: transferOwnership to the final owner, then have them call acceptOwnership().");
    }
}
