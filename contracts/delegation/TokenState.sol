/*
    TokenState.sol - SKALE Manager
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

import "../Permissions.sol";
import "./DelegationController.sol";
import "./TimeHelpers.sol";
import "../interfaces/delegation/ILocker.sol";


/// @notice Store and manage tokens states
contract TokenState is Permissions, ILocker {

    string[] private _lockers;

    function calculateLockedAmount(address holder) external returns (uint locked) {
        uint locked = 0;
        for (uint i = 0; i < _lockers.length; ++i) {
            ILocker locker = ILocker(contractManager.getContract(_lockers[i]));
            locked = locked.add(locker.calculateLockedAmount(holder));
        }
        return locked;
    }

    function calculateForbiddenForDelegationAmount(address holder) external returns (uint amount) {
        uint forbidden = 0;
        for (uint i = 0; i < _lockers.length; ++i) {
            ILocker locker = ILocker(contractManager.getContract(_lockers[i]));
            forbidden = forbidden.add(locker.calculateForbiddenForDelegationAmount(holder));
        }
        return forbidden;
    }

    function removeLocker(string calldata locker) external onlyOwner {
        uint index;
        bytes32 hash = keccak256(abi.encodePacked(locker));
        for (index = 0; index < _lockers.length; ++index) {
            if (keccak256(abi.encodePacked(_lockers[index])) == hash) {
                break;
            }
        }
        if (index < _lockers.length) {
            if (index < _lockers.length - 1) {
                _lockers[index] = _lockers[_lockers.length - 1];
            }
            delete _lockers[_lockers.length - 1];
            --_lockers.length;
        }
    }

    function initialize(address _contractManager) public initializer {
        Permissions.initialize(_contractManager);
        registerLocker("DelegationController");
        registerLocker("Punisher");
        registerLocker("TokenLaunchLocker");
    }

    function registerLocker(string memory locker) public onlyOwner {
        _lockers.push(locker);
    }
}
