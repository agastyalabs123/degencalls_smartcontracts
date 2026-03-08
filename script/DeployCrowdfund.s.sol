// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Crowdfund} from "../src/crowdfund.sol";

contract DeployCrowdfund is Script {
    function run() external {
        uint256 deployerPrivateKey = _readPrivateKey();
        vm.startBroadcast(deployerPrivateKey);

        Crowdfund crowdfund = new Crowdfund();
        console.log("Crowdfund deployed at:", address(crowdfund));

        vm.stopBroadcast();
    }

    /// Reads PRIVATE_KEY from env; accepts with or without "0x" prefix.
    function _readPrivateKey() internal view returns (uint256) {
        string memory pk = vm.envString("PRIVATE_KEY");
        bytes memory b = bytes(pk);
        if (b.length >= 2 && b[0] == "0" && (b[1] == "x" || b[1] == "X")) {
            return vm.parseUint(pk);
        }
        return vm.parseUint(string(abi.encodePacked("0x", pk)));
    }
}
