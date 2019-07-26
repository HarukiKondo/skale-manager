pragma solidity ^0.5.0;

interface INodesFunctionality {
    function createNode(address from, uint value, bytes calldata data) external returns (uint);
    function initWithdrawDeposit(address from, uint nodeIndex) external returns (bool);
    function completeWithdrawDeposit(address from, uint nodeIndex) external returns (uint);
    function removeNode(address from, uint nodeIndex) external;
    function removeNodeByRoot(uint nodeIndex) external;
}