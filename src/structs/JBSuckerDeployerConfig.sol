// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBSuckerDeployer} from "../interfaces/IJBSuckerDeployer.sol";
import {JBTokenMapping} from "./JBTokenMapping.sol";

struct JBSuckerDeployerConfig {
    IJBSuckerDeployer deployer;
    JBTokenMapping[] mappings;
}
