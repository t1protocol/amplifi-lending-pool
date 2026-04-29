// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AmplifiLendingPool} from "../src/AmplifiLendingPool.sol";

contract Deploy is Script {
    function run() external {
        address usdc = vm.envAddress("USDC_ADDRESS");
        address owner = vm.envAddress("OWNER_ADDRESS");
        address teeOperator = vm.envAddress("TEE_OPERATOR_ADDRESS");
        address fundAccount = vm.envAddress("FUND_ACCOUNT_ADDRESS");

        uint256 baseRateBps = vm.envOr("BASE_RATE_BPS", uint256(200));
        uint256 kinkUtilizationBps = vm.envOr("KINK_UTILIZATION_BPS", uint256(8500));
        uint256 kinkRateBps = vm.envOr("KINK_RATE_BPS", uint256(2000));
        uint256 maxRateBps = vm.envOr("MAX_RATE_BPS", uint256(10000));

        vm.startBroadcast();

        AmplifiLendingPool pool = new AmplifiLendingPool(
            usdc, owner, teeOperator, fundAccount, baseRateBps, kinkUtilizationBps, kinkRateBps, maxRateBps
        );

        console2.log("AmplifiLendingPool deployed at:", address(pool));

        vm.stopBroadcast();
    }
}
