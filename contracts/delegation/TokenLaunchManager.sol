/*
    TokenLaunchManager.sol - SKALE Manager
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

pragma solidity 0.6.8;

import "@openzeppelin/contracts/token/ERC777/IERC777.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC777/IERC777Recipient.sol";
import "@openzeppelin/contracts/introspection/IERC1820Registry.sol";

import "../Permissions.sol";
import "./TokenLaunchLocker.sol";


contract TokenLaunchManager is Permissions, IERC777Recipient {
    event Approved(
        address holder,
        uint amount
    );
    event TokensRetrieved(
        address holder,
        uint amount
    );
    event SellerWasRegistered(
        address seller
    );

    IERC1820Registry private _erc1820;

    address public seller;

    mapping (address => uint) public approved;
    uint private _totalApproved;

    modifier onlySeller() {
        require(_isOwner() || _msgSender() == seller, "Not authorized");
        _;
    }

    /// @notice Allocates values for `walletAddresses`
    function approveBatchOfTransfers(address[] calldata walletAddress, uint[] calldata value) external onlySeller {
        require(walletAddress.length == value.length, "Wrong input arrays length");
        for (uint i = 0; i < walletAddress.length; ++i) {
            approveTransfer(walletAddress[i], value[i]);
        }
        require(_totalApproved <= _getBalance(), "Balance is too low");
    }

    function changeApprovalAddress(address oldAddress, address newAddress) external onlySeller {
        require(approved[newAddress] == 0, "New address is already used");
        uint oldValue = approved[oldAddress];
        if (oldValue > 0) {
            _setApprovedAmount(oldAddress, 0);
            approveTransfer(newAddress, oldValue);
        }
    }

    function changeApprovalValue(address wallet, uint newValue) external onlySeller {
        _setApprovedAmount(wallet, newValue);
    }

    /// @notice Transfers the entire value to sender address. Tokens are locked.
    function retrieve() external {
        require(approved[_msgSender()] > 0, "Transfer is not approved");
        uint value = approved[_msgSender()];
        _setApprovedAmount(_msgSender(), 0);
        require(
            IERC20(_contractManager.getContract("SkaleToken")).transfer(_msgSender(), value),
            "Error of token sending");
        TokenLaunchLocker(_contractManager.getContract("TokenLaunchLocker")).lock(_msgSender(), value);
        emit TokensRetrieved(_msgSender(), value);
    }

    function registerSeller(address _seller) external onlyOwner {
        seller = _seller;
        emit SellerWasRegistered(_seller);
    }

    function tokensReceived(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes calldata userData,
        bytes calldata operatorData
    )
        external override
        allow("SkaleToken")
        // solhint-disable-next-line no-empty-blocks
    {

    }

    function initialize(address contractManager) public override initializer {
        Permissions.initialize(contractManager);
        _erc1820 = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);
        _erc1820.setInterfaceImplementer(address(this), keccak256("ERC777TokensRecipient"), address(this));
    }

    function approveTransfer(address walletAddress, uint value) public onlySeller {
        _setApprovedAmount(walletAddress, approved[walletAddress].add(value));
        emit Approved(walletAddress, value);
    }

    // internal

    function _getBalance() internal view returns(uint balance) {
        return IERC20(_contractManager.getContract("SkaleToken")).balanceOf(address(this));
    }

    function _setApprovedAmount(address wallet, uint value) internal {
        uint oldValue = approved[wallet];
        if (oldValue != value) {
            approved[wallet] = value;
            if (value > oldValue) {
                _totalApproved = _totalApproved.add(value - oldValue);
            } else {
                _totalApproved = _totalApproved.sub(oldValue - value);
            }
        }
    }
}