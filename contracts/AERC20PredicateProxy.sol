//SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

import {UpgradableProxy} from "./proxy/UpgradeableProxy.sol";

contract AERC20PredicateProxy is UpgradableProxy {
    constructor(address _proxyTo) UpgradableProxy(_proxyTo) {}
}