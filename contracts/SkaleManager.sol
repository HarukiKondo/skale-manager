/*
    SkaleManager.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Artem Payvin

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

pragma solidity 0.5.16;

import "./Permissions.sol";
import "./interfaces/IConstants.sol";
import "./interfaces/ISkaleToken.sol";
import "./interfaces/ISchainsFunctionality.sol";
import "./interfaces/IManagerData.sol";
import "./delegation/Distributor.sol";
import "./delegation/ValidatorService.sol";
import "./MonitorsFunctionality.sol";
import "./SchainsFunctionality.sol";
import "@openzeppelin/contracts/token/ERC777/IERC777Recipient.sol";
import "@openzeppelin/contracts/introspection/IERC1820Registry.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";


contract SkaleManager is IERC777Recipient, Permissions {
    IERC1820Registry private _erc1820;

    bytes32 constant private TOKENS_RECIPIENT_INTERFACE_HASH = 0xb281fc8c12954d22544db45de3159a39272895b169a852b314f9cc762e44c53b;

    enum TransactionOperation {CreateNode, CreateSchain}

    event BountyGot(
        uint indexed nodeIndex,
        address owner,
        uint32 averageDowntime,
        uint32 averageLatency,
        uint bounty,
        uint32 time,
        uint gasSpend
    );

    function tokensReceived(
        address, // operator
        address from,
        address to,
        uint256 value,
        bytes calldata userData,
        bytes calldata // operator data
    )
        external
        allow("SkaleToken")
    {
        require(to == address(this), "Receiver is incorrect");
        if (userData.length > 0) {
            TransactionOperation operationType = fallbackOperationTypeConvert(userData);
            if (operationType == TransactionOperation.CreateSchain) {
                address schainsFunctionalityAddress = contractManager.getContract("SchainsFunctionality");
                ISchainsFunctionality(schainsFunctionalityAddress).addSchain(from, value, userData);
            }
        }
    }

    function createNode(bytes calldata data) external {
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        ValidatorService validatorService = ValidatorService(contractManager.getContract("ValidatorService"));
        MonitorsFunctionality monitorsFunctionality = MonitorsFunctionality(contractManager.getContract("MonitorsFunctionality"));

        validatorService.checkPossibilityCreatingNode(msg.sender);
        uint nodeIndex = nodes.createNode(msg.sender, data);
        validatorService.pushNode(msg.sender, nodeIndex);
        monitorsFunctionality.addMonitor(nodeIndex);
    }

    function nodeExit(uint nodeIndex) external {
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        SchainsFunctionality schainsFunctionality = SchainsFunctionality(contractManager.getContract("SchainsFunctionality"));
        SchainsData schainsData = SchainsData(contractManager.getContract("SchainsData"));
        IConstants constants = IConstants(contractManager.getContract("ConstantsHolder"));
        schainsFunctionality.freezeSchains(nodeIndex);
        if (nodes.isNodeActive(nodeIndex)) {
            require(nodes.initExit(msg.sender, nodeIndex), "Initialization of node exit is failed");
        }
        bool completed;
        bool schains = false;
        if (schainsData.getActiveSchain(nodeIndex) != bytes32(0)) {
            completed = schainsFunctionality.exitFromSchain(nodeIndex);
            schains = true;
        } else {
            completed = true;
        }
        if (completed) {
            require(nodes.completeExit(msg.sender, nodeIndex), "Finishing of node exit is failed");
            nodes.changeNodeFinishTime(nodeIndex, uint32(now + (schains ? constants.rotationDelay() : 0)));
        }
    }

    function deleteNode(uint nodeIndex) external {
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        nodes.removeNode(msg.sender, nodeIndex);
        MonitorsFunctionality monitorsFunctionality = MonitorsFunctionality(contractManager.getContract("MonitorsFunctionality"));
        monitorsFunctionality.deleteMonitor(nodeIndex);
        ValidatorService validatorService = ValidatorService(contractManager.getContract("ValidatorService"));
        uint validatorId = validatorService.getValidatorIdByNodeAddress(msg.sender);
        validatorService.deleteNode(validatorId, nodeIndex);
    }

    function deleteNodeByRoot(uint nodeIndex) external onlyOwner {
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        MonitorsFunctionality monitorsFunctionality = MonitorsFunctionality(contractManager.getContract("MonitorsFunctionality"));
        ValidatorService validatorService = ValidatorService(contractManager.getContract("ValidatorService"));

        nodes.removeNodeByRoot(nodeIndex);
        monitorsFunctionality.deleteMonitor(nodeIndex);
        uint validatorId = nodes.getNodeValidatorId(nodeIndex);
        validatorService.deleteNode(validatorId, nodeIndex);
    }

    function deleteSchain(string calldata name) external {
        address schainsFunctionalityAddress = contractManager.getContract("SchainsFunctionality");
        ISchainsFunctionality(schainsFunctionalityAddress).deleteSchain(msg.sender, name);
    }

    function deleteSchainByRoot(string calldata name) external onlyOwner {
        address schainsFunctionalityAddress = contractManager.getContract("SchainsFunctionality");
        ISchainsFunctionality(schainsFunctionalityAddress).deleteSchainByRoot(name);
    }

    function sendVerdict(
        uint fromMonitorIndex,
        uint toNodeIndex,
        uint32 downtime,
        uint32 latency) external
    {
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        MonitorsFunctionality monitorsFunctionality = MonitorsFunctionality(contractManager.getContract("MonitorsFunctionality"));

        require(nodes.isNodeExist(msg.sender, fromMonitorIndex), "Node does not exist for Message sender");

        monitorsFunctionality.sendVerdict(
            fromMonitorIndex,
            toNodeIndex,
            downtime,
            latency);
    }

    function sendVerdicts(
        uint fromMonitorIndex,
        uint[] calldata toNodeIndexes,
        uint32[] calldata downtimes,
        uint32[] calldata latencies) external
    {
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        require(nodes.isNodeExist(msg.sender, fromMonitorIndex), "Node does not exist for Message sender");
        require(toNodeIndexes.length == downtimes.length, "Incorrect data");
        require(latencies.length == downtimes.length, "Incorrect data");
        MonitorsFunctionality monitorsFunctionalityAddress = MonitorsFunctionality(contractManager.getContract("MonitorsFunctionality"));
        for (uint i = 0; i < toNodeIndexes.length; i++) {
            monitorsFunctionalityAddress.sendVerdict(
                fromMonitorIndex,
                toNodeIndexes[i],
                downtimes[i],
                latencies[i]);
        }
    }

    function getBounty(uint nodeIndex) external {
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        require(nodes.isNodeExist(msg.sender, nodeIndex), "Node does not exist for Message sender");
        require(nodes.isTimeForReward(nodeIndex), "Not time for bounty");
        bool nodeIsActive = nodes.isNodeActive(nodeIndex);
        bool nodeIsLeaving = nodes.isNodeLeaving(nodeIndex);
        require(nodeIsActive || nodeIsLeaving, "Node is not Active and is not Leaving");
        uint32 averageDowntime;
        uint32 averageLatency;
        MonitorsFunctionality monitorsFunctionality = MonitorsFunctionality(contractManager.getContract("MonitorsFunctionality"));
        (averageDowntime, averageLatency) = monitorsFunctionality.calculateMetrics(nodeIndex);
        uint bounty = manageBounty(
            msg.sender,
            nodeIndex,
            averageDowntime,
            averageLatency);
        nodes.changeNodeLastRewardDate(nodeIndex);
        monitorsFunctionality.upgradeMonitor(nodeIndex);
        emit BountyGot(
            nodeIndex,
            msg.sender,
            averageDowntime,
            averageLatency,
            bounty,
            uint32(block.timestamp),
            gasleft());
    }

    function initialize(address newContractsAddress) public initializer {
        Permissions.initialize(newContractsAddress);
        _erc1820 = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);
        _erc1820.setInterfaceImplementer(address(this), TOKENS_RECIPIENT_INTERFACE_HASH, address(this));
    }

    function manageBounty(
        address from,
        uint nodeIndex,
        uint32 downtime,
        uint32 latency) internal returns (uint)
    {
        uint commonBounty;
        IConstants constants = IConstants(contractManager.getContract("ConstantsHolder"));
        IManagerData managerData = IManagerData(contractManager.getContract("ManagerData"));
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));

        uint diffTime = nodes.getNodeLastRewardDate(nodeIndex)
            .add(constants.rewardPeriod())
            .add(constants.deltaPeriod());
        if (managerData.minersCap() == 0) {
            managerData.setMinersCap(ISkaleToken(contractManager.getContract("SkaleToken")).CAP() / 3);
        }
        if (managerData.stageTime().add(constants.rewardPeriod()) < now) {
            managerData.setStageTimeAndStageNodes(nodes.numberOfActiveNodes().add(nodes.numberOfLeavingNodes()));
        }
        commonBounty = managerData.minersCap()
            .div((2 ** (((now.sub(managerData.startTime()))
            .div(constants.SIX_YEARS())) + 1))
            .mul((constants.SIX_YEARS()
            .div(constants.rewardPeriod())))
            .mul(managerData.stageNodes()));
        if (now > diffTime) {
            diffTime = now.sub(diffTime);
        } else {
            diffTime = 0;
        }
        diffTime = diffTime.div(constants.checkTime());
        int bountyForMiner = int(commonBounty);
        uint normalDowntime = ((constants.rewardPeriod().sub(constants.deltaPeriod())).div(constants.checkTime())) / 30;
        if (downtime.add(diffTime) > normalDowntime) {
            bountyForMiner -= int(((downtime.add(diffTime)).mul(commonBounty)) / (constants.SECONDS_TO_DAY() / 4));
        }

        if (bountyForMiner > 0) {
            if (latency > constants.allowableLatency()) {
                bountyForMiner = int((constants.allowableLatency().mul(uint(bountyForMiner))).div(latency));
            }
            payBounty(uint(bountyForMiner), from, nodeIndex);
        } else {
            //Need to add penalty
            bountyForMiner = 0;
        }
        return uint(bountyForMiner);
    }

    function payBounty(uint bountyForMiner, address miner, uint nodeIndex) internal returns (bool) {
        ValidatorService validatorService = ValidatorService(contractManager.getContract("ValidatorService"));
        SkaleToken skaleToken = SkaleToken(contractManager.getContract("SkaleToken"));
        Distributor distributor = Distributor(contractManager.getContract("Distributor"));

        uint validatorId = validatorService.getValidatorIdByNodeAddress(miner);
        uint bounty = bountyForMiner;
        if (!validatorService.checkPossibilityToMaintainNode(validatorId, nodeIndex)) {
            bounty /= 2;
        }
        skaleToken.send(address(distributor), bounty, abi.encode(validatorId));
    }

    function fallbackOperationTypeConvert(bytes memory data) internal pure returns (TransactionOperation) {
        bytes1 operationType;
        assembly {
            operationType := mload(add(data, 0x20))
        }
        bool isIdentified = operationType == bytes1(uint8(1)) ||
            operationType == bytes1(uint8(16)) ||
            operationType == bytes1(uint8(2));
        require(isIdentified, "Operation type is not identified");
        if (operationType == bytes1(uint8(1))) {
            return TransactionOperation.CreateNode;
        } else if (operationType == bytes1(uint8(16))) {
            return TransactionOperation.CreateSchain;
        }
    }

}
