// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CollateralEscrow} from "../src/CollateralEscrow.sol";

contract DeployCollateralEscrow is Script {
    function run() external {
        address owner = vm.envAddress("OWNER_ADDRESS");
        address collateralToken = vm.envOr("COLLATERAL_TOKEN_ADDRESS", address(0));
        address attester = vm.envOr("ATTESTER_ADDRESS", address(0));
        address seizer = vm.envOr("SEIZER_ADDRESS", address(0));

        console2.log("=== CollateralEscrow deploy ===");
        console2.log("Owner:            ", owner);
        console2.log("Collateral token: ", collateralToken);
        console2.log("Attester:         ", attester);
        console2.log("Seizer:           ", seizer);

        vm.startBroadcast();
        CollateralEscrow escrow = new CollateralEscrow(owner);
        // Optional setup — requires the broadcaster to be `owner`; skipped when unset.
        if (collateralToken != address(0)) escrow.setCollateralAllowed(collateralToken, true);
        if (attester != address(0)) escrow.setAttester(attester, true);
        if (seizer != address(0)) escrow.setSeizer(seizer, true);
        vm.stopBroadcast();

        console2.log("Deployed at:", address(escrow));
        console2.log("Next: transferOwnership to the final owner, then have them call acceptOwnership().");
    }
}
