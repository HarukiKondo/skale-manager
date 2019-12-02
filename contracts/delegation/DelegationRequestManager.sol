/*
    DelegationRequestManager.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Vadim Yavorsky
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

import "../Permissions.sol";
import "../interfaces/IDelegationPeriodManager.sol";
import "../interfaces/delegation/IValidatorDelegation.sol";
import "../interfaces/delegation/IDelegatableToken.sol";
import "../thirdparty/BokkyPooBahsDateTimeLibrary.sol";
import "./ValidatorDelegation.sol";
import "./DelegationController.sol";
import "../SkaleToken.sol";


interface IDelegationController {
    function delegate(uint _requestId) external;
}


contract DelegationRequestManager is Permissions {

    struct DelegationRequest {
        address tokenAddress;
        uint validatorId;
        uint tokenAmount;
        uint delegationPeriod;
        uint unlockedUntill;
        string description;
    }

    DelegationRequest[] public delegationRequests;
    mapping (address => uint[]) public delegationRequestsByTokenAddress;
    mapping (address => bool) public delegated;


    constructor(address newContractsAddress) Permissions(newContractsAddress) public {

    }

    modifier checkValidatorAccess(uint _requestId) {
        ValidatorDelegation validatorDelegation = ValidatorDelegation(
            contractManager.getContract("ValidatorDelegation")
        );
        require(_requestId < delegationRequests.length, "Delegation request doesn't exist");
        require(
            validatorDelegation.checkValidatorAddressToId(msg.sender, delegationRequests[_requestId].validatorId),
            "Transaction sender hasn't permissions to change status of request"
        );
        _;
    }

    function createRequest(
        address tokenAddress,
        uint validatorId,
        uint tokenAmount,
        uint delegationPeriod,
        string calldata info
    )
        external returns(uint requestId)
    {
        IDelegationPeriodManager delegationPeriodManager = IDelegationPeriodManager(
            contractManager.getContract("DelegationPeriodManager")
        );
        IValidatorDelegation validatorDelegation = IValidatorDelegation(
            contractManager.getContract("ValidatorDelegation")
        );
        require(!delegated[tokenAddress], "Token is already in the process of delegation");
        require(
            delegationPeriodManager.isDelegationPeriodAllowed(delegationPeriod),
            "This delegation period is not allowed"
        );
        // check that holder has enough tokens to delegate
        uint holderBalance = SkaleToken(contractManager.getContract("SkaleToken")).balanceOf(tokenAddress);
        uint unavailableTokens = DelegationController(contractManager.getContract("DelegationController")).delegated(tokenAddress);
        require(holderBalance - unavailableTokens >= tokenAmount, "Delegator hasn't enough tokens to delegate");
        require(validatorDelegation.validatorExists(validatorId), "Validator is not registered");
        uint expirationRequest = calculateExpirationRequest();
        delegationRequests.push(DelegationRequest(
            tokenAddress,
            validatorId,
            tokenAmount,
            delegationPeriod,
            expirationRequest,
            info
        ));
        requestId = delegationRequests.length-1;
        delegationRequestsByTokenAddress[tokenAddress].push(requestId);
    }

    function checkValidityRequest(uint _requestId) public view returns (bool) {
        require(delegationRequests[_requestId].tokenAddress != address(0), "Token address doesn't exist");
        return delegationRequests[_requestId].unlockedUntill > now ? true : false;
    }

    function acceptRequest(uint _requestId) public checkValidatorAccess(_requestId) {
        IDelegationController delegationController = IDelegationController(
            contractManager.getContract("DelegationController")
        );
        IDelegatableToken skaleToken = IDelegatableToken(
            contractManager.getContract("SkaleToken")
        );
        skaleToken.lock(delegationRequests[_requestId].tokenAddress);
        delegated[delegationRequests[_requestId].tokenAddress] = true;

        require(checkValidityRequest(_requestId), "Validator can't longer accept delegation request");
        delegationController.delegate(_requestId);
    }

    function cancelRequest(uint _requestId) external {
        require(_requestId < delegationRequests.length, "Delegation request doesn't exist");
        require(
            msg.sender == delegationRequests[_requestId].tokenAddress,
            "Only token holder can cancel request"
        );
        delete delegationRequests[_requestId];
    }

    // function getAllDelegationRequests() public view returns (DelegationRequest[] memory) {
    //     return delegationRequests;
    // }

    function getDelegationRequestsForValidator(uint validatorId) external returns (DelegationRequest[] memory) {

    }

    function calculateExpirationRequest() private view returns (uint timestamp) {
        uint year;
        uint month;
        uint nextYear;
        uint nextMonth;
        (year, month, ) = BokkyPooBahsDateTimeLibrary.timestampToDate(now);
        if (month != 12) {
            nextMonth = month + 1;
            nextYear = year;
        } else {
            nextMonth = 1;
            nextYear = year + 1;
        }
        timestamp = BokkyPooBahsDateTimeLibrary.timestampFromDate(nextYear, nextMonth, 1);
    }

    function getDelegationPeriod(uint requestId) public view returns (uint) {
        return delegationRequests[requestId].delegationPeriod;
    }

    function getValidatorId(uint requestId) public view returns (uint) {
        return delegationRequests[requestId].validatorId;
    }

    function getTokenAddress(uint requestId) public view returns (address) {
        return delegationRequests[requestId].tokenAddress;
    }

    function getTokenAmount(uint requestId) public view returns (uint) {
        return delegationRequests[requestId].tokenAmount;
    }
}