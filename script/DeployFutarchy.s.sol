// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.20;

// import {Script, console} from "forge-std/Script.sol";
// import {FutarchyCrowdfund} from "../src/futarchy/FutarchyCrowdfund.sol";

// /**
//  * @title DeployFutarchy
//  * @notice Deploys FutarchyCrowdfund (which deploys DecisionOracle internally).
//  *        Requires an existing PredictionMarketFactory address.
//  * @dev Env: PRIVATE_KEY, MARKET_FACTORY (PredictionMarketFactory).
//  */
// contract DeployFutarchy is Script {
//     function run() external {
//         uint256 deployerPrivateKey = _readPrivateKey();

//         address marketFactory = vm.envAddress("MARKET_FACTORY");

//         vm.startBroadcast(deployerPrivateKey);

//         FutarchyCrowdfund crowdfund = new FutarchyCrowdfund(marketFactory);
//         console.log("FutarchyCrowdfund at:", address(crowdfund));
//         console.log("DecisionOracle at:", address(crowdfund.oracle()));

//         vm.stopBroadcast();
//     }

//     function _readPrivateKey() internal view returns (uint256) {
//         string memory pk = vm.envString("PRIVATE_KEY");
//         bytes memory b = bytes(pk);
//         if (b.length >= 2 && b[0] == "0" && (b[1] == "x" || b[1] == "X")) {
//             return vm.parseUint(pk);
//         }
//         return vm.parseUint(string(abi.encodePacked("0x", pk)));
//     }
// }
