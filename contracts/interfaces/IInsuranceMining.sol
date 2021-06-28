//SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IInsuranceMining {
    function pendingMining(uint256 marketId, address insurant, address policyHolder, uint256 amount) external;
}
