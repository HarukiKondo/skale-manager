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
import "./DelegationPeriodManager.sol";
import "./ValidatorService.sol";
import "../interfaces/delegation/IDelegatableToken.sol";
import "../thirdparty/BokkyPooBahsDateTimeLibrary.sol";
import "./ValidatorService.sol";
import "./DelegationController.sol";
import "../SkaleToken.sol";
import "./TokenState.sol";


/**
    @notice Handles Delegation Requests <br>
            Requests are created/canceled by the delegator <br>
            Requests are accepted by the validator
*/
contract DelegationRequestManager is Permissions {


    constructor(address newContractsAddress) Permissions(newContractsAddress) public {

    }

    /**
        @notice creates a Delegation Request
        @dev Changes TokenState to PROPOSED!
        @param validatorId Id of the validator
        @param amount amount of tokens to be used for delegation
        @param delegationPeriod delegation period (3,6,12)
        @param info information about the delegation request

        Requirement
        -
        Delegation period should be allowed
        Validator should be registered
        Delegator should have enough tokens to delegate, checks the account holder balance through SKALEToken contract
    */
    function createRequest(
        address holder,
        uint validatorId,
        uint amount,
        uint delegationPeriod,
        string calldata info
    )
        external
        returns (uint delegationId)
    {
        ValidatorService validatorService = ValidatorService(
            contractManager.getContract("ValidatorService")
        );
        DelegationPeriodManager delegationPeriodManager = DelegationPeriodManager(
            contractManager.getContract("DelegationPeriodManager")
        );
        TokenState tokenState = TokenState(
            contractManager.getContract("TokenState")
        );
        DelegationController delegationController = DelegationController(
            contractManager.getContract("DelegationController")
        );
        require(
            validatorService.checkMinimumDelegation(validatorId, amount),
            "Amount doesn't meet minimum delegation amount"
        );
        require(
            delegationPeriodManager.isDelegationPeriodAllowed(delegationPeriod),
            "This delegation period is not allowed"
        );
        require(validatorService.checkValidatorExists(validatorId), "Validator is not registered");
        delegationId = delegationController.addDelegation(
            holder,
            validatorId,
            amount,
            delegationPeriod,
            now,
            info
        );
        uint holderBalance = SkaleToken(contractManager.getContract("SkaleToken")).balanceOf(holder);
        uint lockedToDelegate = tokenState.getLockedCount(holder) - tokenState.getPurchasedAmount(holder);
        require(holderBalance - lockedToDelegate >= amount, "Delegator hasn't enough tokens to delegate");
    }

    /**
        @notice cancels a Delegation Request
        @param delegationId Id of the delegation Request

        Requirement
        -

        Only token holder can cancel request
        After cancellation token should be COMPLETED
     */
    function cancelRequest(uint delegationId) external {
        TokenState tokenState = TokenState(
            contractManager.getContract("TokenState")
        );
        DelegationController delegationController = DelegationController(
            contractManager.getContract("DelegationController")
        );
        DelegationController.Delegation memory delegation = delegationController.getDelegation(delegationId);
        require(msg.sender == delegation.holder,"No permissions to cancel request");
        require(
            tokenState.cancel(delegationId) == TokenState.State.COMPLETED,
            "After cancellation token should be COMPLETED");
    }

    /**
        @notice validator calls this function to accept a Delegation Request
        @param delegationId Id of the delegation Request

        Requirement
        -
        Only token holder can cancel request
    */
    function acceptRequest(uint delegationId) external {
        TokenState tokenState = TokenState(
            contractManager.getContract("TokenState")
        );
        DelegationController delegationController = DelegationController(
            contractManager.getContract("DelegationController")
        );
        ValidatorService validatorService = ValidatorService(
            contractManager.getContract("ValidatorService")
        );
        DelegationController.Delegation memory delegation = delegationController.getDelegation(delegationId);
        require(
            validatorService.checkValidatorAddressToId(msg.sender, delegation.validatorId),
            "No permissions to accept request"
        );
        delegationController.delegate(delegationId);
        tokenState.accept(delegationId);
    }

}
