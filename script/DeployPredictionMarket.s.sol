// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PredictionMarketFactory} from "../src/predictionMarket/PredictionMarketFactory.sol";

/**
 * @title DeployPredictionMarket
 * @notice Deploys PredictionMarketFactory and logs critical addresses.
 */
contract DeployPredictionMarket is Script {
    function run() external {
        // 1. Setup: Load private key and derive address
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);

        // Configuration
        bool permissionless = true;

        console.log("-----------------------------------------");
        console.log("Deployer Address:", deployerAddress);
        console.log("Deployer Balance:", deployerAddress.balance);
        console.log("-----------------------------------------");

        // 2. Execution: Broadcast the transaction
        vm.startBroadcast(deployerPrivateKey);

        PredictionMarketFactory factory = new PredictionMarketFactory();

        vm.stopBroadcast();

        // 3. Output results
        console.log("PredictionMarketFactory deployed to:", address(factory));
        console.log("-----------------------------------------");
    }
}
