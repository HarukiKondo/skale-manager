/*
    ValidatorService.sol - SKALE Manager
    Copyright (C) 2019-Present SKALE Labs
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity ^0.5.3;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";

import "../Permissions.sol";
import "../interfaces/IConstants.sol";

import "./DelegationController.sol";


contract ValidatorService is Permissions {

    struct Validator {
        string name;
        address validatorAddress;
        address requestedAddress;
        string description;
        uint feeRate;
        uint registrationTime;
        uint minimumDelegationAmount;
        uint[] nodeIndexes;
    }

    mapping (uint => Validator) public validators;
    mapping (uint => bool) public trustedValidators;
    ///      address => validatorId
    mapping (address => uint) private _validatorAddressToId;
    ///      address => validatorId
    mapping (address => uint) private _nodeAddressToValidatorId;
    /// validatorId => nodeAddress[]
    mapping (uint => address[]) private _nodeAddresses;
    uint public numberOfValidators;

    modifier checkValidatorExists(uint validatorId) {
        require(validatorExists(validatorId), "Validator with such id doesn't exist");
        _;
    }

    function registerValidator(
        string calldata name,
        address validatorAddress,
        string calldata description,
        uint feeRate,
        uint minimumDelegationAmount
    )
        external
        allow("DelegationService")
        returns (uint validatorId)
    {
        require(!validatorAddressExists(validatorAddress), "Validator with such address already exists");
        require(feeRate < 1000, "Fee rate of validator should be lower than 100%");
        uint[] memory epmtyArray = new uint[](0);
        validatorId = ++numberOfValidators;
        validators[validatorId] = Validator(
            name,
            validatorAddress,
            address(0),
            description,
            feeRate,
            now,
            minimumDelegationAmount,
            epmtyArray
        );
        setValidatorAddress(validatorId, validatorAddress);
    }

    function enableValidator(uint validatorId) external checkValidatorExists(validatorId) onlyOwner {
        trustedValidators[validatorId] = true;
    }

    function disableValidator(uint validatorId) external checkValidatorExists(validatorId) onlyOwner {
        trustedValidators[validatorId] = false;
    }

    function getTrustedValidators() external view returns (uint[] memory) {
        uint numberOfTrustedValidators = 0;
        for (uint i = 1; i <= numberOfValidators; i++) {
            if (trustedValidators[i]) {
                numberOfTrustedValidators++;
            }
        }
        uint[] memory whitelist = new uint[](numberOfTrustedValidators);
        uint cursor = 0;
        for (uint i = 1; i <= numberOfValidators; i++) {
            if (trustedValidators[i]) {
                whitelist[cursor++] = i;
            }
        }
        return whitelist;
    }

    function requestForNewAddress(address oldValidatorAddress, address newValidatorAddress) external allow("DelegationService") {
        require(newValidatorAddress != address(0), "New address cannot be null");
        uint validatorId = getValidatorId(oldValidatorAddress);
        validators[validatorId].requestedAddress = newValidatorAddress;
    }

    function confirmNewAddress(address newValidatorAddress, uint validatorId)
        external
        checkValidatorExists(validatorId)
        allow("DelegationService")
    {
        validators[validatorId].requestedAddress = address(0);
        setValidatorAddress(validatorId, validators[validatorId].validatorAddress);
    }

    function linkNodeAddress(address validatorAddress, address nodeAddress) external allow("DelegationService") {
        uint validatorId = getValidatorId(validatorAddress);
        addNodeAddress(validatorId, nodeAddress);
    }

    function unlinkNodeAddress(address validatorAddress, address nodeAddress) external allow("DelegationService") {
        uint validatorId = getValidatorId(validatorAddress);
        removeNodeAddress(validatorId, nodeAddress);
    }

    function checkMinimumDelegation(uint validatorId, uint amount)
        external view
        checkValidatorExists(validatorId)
        allow("DelegationController")
        returns (bool)
    {
        return validators[validatorId].minimumDelegationAmount <= amount ? true : false;
    }

    function checkValidatorAddressToId(address validatorAddress, uint validatorId)
        external
        view
        returns (bool)
    {
        return getValidatorId(validatorAddress) == validatorId ? true : false;
    }

    function getValidatorNodeIndexes(uint validatorId) external view returns (uint[] memory) {
        return getValidator(validatorId).nodeIndexes;
    }

    function pushNode(address validatorAddress, uint nodeIndex) external allow("SkaleManager") {
        uint validatorId = getValidatorId(validatorAddress);
        validators[validatorId].nodeIndexes.push(nodeIndex);
    }

    function deleteNode(uint validatorId, uint nodeIndex) external allow("SkaleManager") {
        uint[] memory validatorNodes = validators[validatorId].nodeIndexes;
        uint position = findNode(validatorNodes, nodeIndex);
        if (position < validatorNodes.length) {
            validators[validatorId].nodeIndexes[position] = validators[validatorId].nodeIndexes[validatorNodes.length.sub(1)];
        }
        delete validators[validatorId].nodeIndexes[validatorNodes.length.sub(1)];
    }

    function checkPossibilityCreatingNode(address validatorAddress) external allow("SkaleManager") {
        DelegationController delegationController = DelegationController(
            contractManager.getContract("DelegationController")
        );
        uint validatorId = getValidatorId(validatorAddress);
        require(trustedValidators[validatorId], "Validator is not authorized to create a node");
        uint[] memory validatorNodes = validators[validatorId].nodeIndexes;
        uint delegationsTotal = delegationController.getAndUpdateDelegatedToValidatorNow(validatorId);
        uint msr = IConstants(contractManager.getContract("ConstantsHolder")).msr();
        require((validatorNodes.length.add(1)) * msr <= delegationsTotal, "Validator has to meet Minimum Staking Requirement");
    }

    function checkPossibilityToMaintainNode(uint validatorId, uint nodeIndex) external allow("SkaleManager") returns (bool) {
        DelegationController delegationController = DelegationController(
            contractManager.getContract("DelegationController")
        );
        uint[] memory validatorNodes = validators[validatorId].nodeIndexes;
        uint position = findNode(validatorNodes, nodeIndex);
        require(position < validatorNodes.length, "Node does not exist for this Validator");
        uint delegationsTotal = delegationController.getAndUpdateDelegatedToValidatorNow(validatorId);
        uint msr = IConstants(contractManager.getContract("ConstantsHolder")).msr();
        return position.add(1).mul(msr) <= delegationsTotal;
    }

    function getMyNodesAddresses() external view returns (address[] memory) {
        return getNodeAddresses(getValidatorId(msg.sender));
    }

    /// @notice return how many of validator funds are locked in SkaleManager
    function getAndUpdateBondAmount(uint validatorId)
        external
        returns (uint delegatedAmount)
    {
        DelegationController delegationController = DelegationController(contractManager.getContract("DelegationController"));
        return delegationController.getAndUpdateDelegatedAmount(validators[validatorId].validatorAddress);
    }

    function setValidatorName(string calldata newName) external {
        uint validatorId = getValidatorId(msg.sender);
        validators[validatorId].name = newName;
    }

    function setValidatorDescription(string calldata newDescription) external {
        uint validatorId = getValidatorId(msg.sender);
        validators[validatorId].description = newDescription;
    }

    function getValidatorIdByNodeAddress(address nodeAddress) external view returns (uint validatorId) {
        validatorId = _nodeAddressToValidatorId[nodeAddress];
        require(validatorId != 0, "Node address is not assigned to a validator");
    }

    function initialize(address _contractManager) public initializer {
        Permissions.initialize(_contractManager);
    }

    function getNodeAddresses(uint validatorId) public view returns (address[] memory) {
        return _nodeAddresses[validatorId];
    }

    function validatorExists(uint validatorId) public view returns (bool) {
        return validatorId <= numberOfValidators;
    }

    function validatorAddressExists(address validatorAddress) public view returns (bool) {
        return _validatorAddressToId[validatorAddress] != 0;
    }

    function checkIfValidatorAddressExists(address validatorAddress) public view {
        require(validatorAddressExists(validatorAddress), "Validator with such address doesn't exist");
    }

    function getValidator(uint validatorId) public view checkValidatorExists(validatorId) returns (Validator memory) {
        return validators[validatorId];
    }

    function getValidatorId(address validatorAddress) public view returns (uint) {
        checkIfValidatorAddressExists(validatorAddress);
        return _validatorAddressToId[validatorAddress];
    }

    // private

    function findNode(uint[] memory nodeIndexes, uint nodeIndex) internal pure returns (uint) {
        uint i;
        for (i = 0; i < nodeIndexes.length; i++) {
            if (nodeIndexes[i] == nodeIndex) {
                return i;
            }
        }
        return i;
    }

    function setValidatorAddress(uint validatorId, address validatorAddress) internal {
        if (_validatorAddressToId[validatorAddress] == validatorId) {
            return;
        }
        require(_validatorAddressToId[validatorAddress] == 0, "Address is in use by the another validator");
        address oldAddress = validators[validatorId].validatorAddress;
        delete _validatorAddressToId[oldAddress];
        validators[validatorId].validatorAddress = validatorAddress;
        _validatorAddressToId[validatorAddress] = validatorId;
    }

    function addNodeAddress(uint validatorId, address nodeAddress) internal {
        if (_nodeAddressToValidatorId[nodeAddress] == validatorId) {
            return;
        }
        require(_nodeAddressToValidatorId[nodeAddress] == 0, "Validator cannot override node address");
        _nodeAddressToValidatorId[nodeAddress] = validatorId;
        _nodeAddresses[validatorId].push(nodeAddress);
    }

    function removeNodeAddress(uint validatorId, address nodeAddress) internal {
        require(_validatorAddressToId[nodeAddress] == validatorId, "Validator hasn't permissions to unlink node");
        delete _validatorAddressToId[nodeAddress];
        for (uint i = 0; i < _nodeAddresses[validatorId].length; ++i) {
            if (_nodeAddresses[validatorId][i] == nodeAddress) {
                if (i + 1 < _nodeAddresses[validatorId].length) {
                    _nodeAddresses[validatorId][i] = _nodeAddresses[validatorId][_nodeAddresses[validatorId].length.sub(1)];
                }
                delete _nodeAddresses[validatorId][_nodeAddresses[validatorId].length.sub(1)];
                --_nodeAddresses[validatorId].length;
                break;
            }
        }
    }
}
