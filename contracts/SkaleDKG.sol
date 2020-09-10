// SPDX-License-Identifier: AGPL-3.0-only

/*
    SkaleDKG.sol - SKALE Manager
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

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;
import "./Permissions.sol";
import "./delegation/Punisher.sol";
import "./SlashingTable.sol";
import "./Schains.sol";
import "./SchainsInternal.sol";
import "./utils/FieldOperations.sol";
import "./NodeRotation.sol";
import "./KeyStorage.sol";
import "./interfaces/ISkaleDKG.sol";
import "./ECDH.sol";
import "./utils/Precompiled.sol";

contract SkaleDKG is Permissions, ISkaleDKG {
    using Fp2Operations for Fp2Operations.Fp2Point;
    using G2Operations for G2Operations.G2Point;

    struct Channel {
        bool active;
        uint n;
        uint startedBlockTimestamp;
        uint startedBlock;
    }

    struct ProcessDKG {
        uint numberOfBroadcasted;
        uint numberOfCompleted;
        bool[] broadcasted;
        bool[] completed;
    }

    struct ComplaintData {
        uint nodeToComplaint;
        uint fromNodeToComplaint;
        uint startComplaintBlockTimestamp;
    }

    struct KeyShare {
        bytes32[2] publicKey;
        bytes32 share;
    }

    uint public constant COMPLAINT_TIMELIMIT = 1800;

    mapping(bytes32 => Channel) public channels;

    mapping(bytes32 => uint) public lastSuccesfulDKG;

    mapping(bytes32 => ProcessDKG) public dkgProcess;

    mapping(bytes32 => ComplaintData) public complaints;

    mapping(bytes32 => uint) public startAlrightTimestamp;

    mapping(bytes32 => mapping(uint => bytes32)) public hashedData;

    event ChannelOpened(bytes32 schainId);

    event ChannelClosed(bytes32 schainId);

    event BroadcastAndKeyShare(
        bytes32 indexed schainId,
        uint indexed fromNode,
        G2Operations.G2Point[] verificationVector,
        KeyShare[] secretKeyContribution
    );

    event AllDataReceived(bytes32 indexed schainId, uint nodeIndex);
    event SuccessfulDKG(bytes32 indexed schainId);
    event BadGuy(uint nodeIndex);
    event FailedDKG(bytes32 indexed schainId);
    event ComplaintSent(bytes32 indexed schainId, uint indexed fromNodeIndex, uint indexed toNodeIndex);
    event NewGuy(uint nodeIndex);
    event ComplaintError(string error);

    modifier correctGroup(bytes32 schainId) {
        require(channels[schainId].active, "Group is not created");
        _;
    }

    modifier correctGroupWithoutRevert(bytes32 schainId) {
        if (!channels[schainId].active) {
            emit ComplaintError("Group is not created");
        } else {
            _;
        }
    }

    modifier correctNode(bytes32 schainId, uint nodeIndex) {
        uint index = _nodeIndexInSchain(schainId, nodeIndex);
        require(
            index < channels[schainId].n,
            "Node is not in this group");
        _;
    }

    modifier correctNodeWithoutRevert(bytes32 schainId, uint nodeIndex) {
        uint index = _nodeIndexInSchain(schainId, nodeIndex);
        if (index >= channels[schainId].n) {
            emit ComplaintError("Node is not in this group");
        } else {
            _;
        }
    }

    function openChannel(bytes32 schainId) external override allowTwo("Schains","NodeRotation") {
        _openChannel(schainId);
    }

    function deleteChannel(bytes32 schainId) external override allow("SchainsInternal") {
        delete channels[schainId];
        delete dkgProcess[schainId];
        delete complaints[schainId];
        KeyStorage(contractManager.getContract("KeyStorage")).deleteKey(schainId);
    }

    function broadcast(
        bytes32 schainId,
        uint nodeIndex,
        G2Operations.G2Point[] calldata verificationVector,
        KeyShare[] calldata secretKeyContribution
    )
        external
        correctGroup(schainId)
    {
        require(_isNodeByMessageSender(nodeIndex, msg.sender), "Node does not exist for message sender");
        uint n = channels[schainId].n;
        require(verificationVector.length == getT(n), "Incorrect number of verification vectors");
        require(
            secretKeyContribution.length == n,
            "Incorrect number of secret key shares"
        );
        uint index = _nodeIndexInSchain(schainId, nodeIndex);
        require(index < channels[schainId].n, "Node is not in this group");
        require(!dkgProcess[schainId].broadcasted[index], "This node has already broadcasted");
        dkgProcess[schainId].broadcasted[index] = true;
        dkgProcess[schainId].numberOfBroadcasted++;
        if (dkgProcess[schainId].numberOfBroadcasted == channels[schainId].n) {
            startAlrightTimestamp[schainId] = now;
        }
        hashedData[schainId][index] = _hashData(secretKeyContribution, verificationVector);
        KeyStorage keyStorage = KeyStorage(contractManager.getContract("KeyStorage"));
        keyStorage.adding(schainId, verificationVector[0]);
        emit BroadcastAndKeyShare(
            schainId,
            nodeIndex,
            verificationVector,
            secretKeyContribution
        );
    }

    function complaint(bytes32 schainId, uint fromNodeIndex, uint toNodeIndex)
        external
        correctGroupWithoutRevert(schainId)
        correctNode(schainId, fromNodeIndex)
        correctNodeWithoutRevert(schainId, toNodeIndex)
    {
        require(_isNodeByMessageSender(fromNodeIndex, msg.sender), "Node does not exist for message sender");
        require(isNodeBroadcasted(schainId, fromNodeIndex), "Node has not broadcasted");
        bool broadcasted = isNodeBroadcasted(schainId, toNodeIndex);
        if (broadcasted) {
            _handleComplaintWhenBroadcasted(schainId, fromNodeIndex, toNodeIndex);
            return;
        } else {
            // not broadcasted in 30 min
            if (channels[schainId].startedBlockTimestamp.add(COMPLAINT_TIMELIMIT) <= block.timestamp) {
                _finalizeSlashing(schainId, toNodeIndex);
                return;
            }
            emit ComplaintError("Complaint sent too early");
            return;
        }
    }

    function response(
        bytes32 schainId,
        uint fromNodeIndex,
        uint secretNumber,
        G2Operations.G2Point calldata multipliedShare,
        G2Operations.G2Point[] calldata verificationVector,
        KeyShare[] calldata secretKeyContribution
    )
        external
        correctGroup(schainId)
    {
        uint indexOnSchain = _nodeIndexInSchain(schainId, fromNodeIndex);
        require(indexOnSchain < channels[schainId].n, "Node is not in this group");
        require(complaints[schainId].nodeToComplaint == fromNodeIndex, "Not this Node");
        require(_isNodeByMessageSender(fromNodeIndex, msg.sender), "Node does not exist for message sender");
        require(
            hashedData[schainId][indexOnSchain] == _hashData(secretKeyContribution, verificationVector),
            "Broadcasted Data is not correct"
        );
        uint index = _nodeIndexInSchain(schainId, complaints[schainId].fromNodeToComplaint);
        _verifyDataAndSlash(
            schainId,
            indexOnSchain,
            secretNumber,
            multipliedShare,
            verificationVector,
            secretKeyContribution[index].share
         );
    }

    function alright(bytes32 schainId, uint fromNodeIndex)
        external
        correctGroup(schainId)
        correctNode(schainId, fromNodeIndex)
    {
        require(_isNodeByMessageSender(fromNodeIndex, msg.sender), "Node does not exist for message sender");
        uint index = _nodeIndexInSchain(schainId, fromNodeIndex);
        uint numberOfParticipant = channels[schainId].n;
        require(numberOfParticipant == dkgProcess[schainId].numberOfBroadcasted, "Still Broadcasting phase");
        require(
            complaints[schainId].fromNodeToComplaint != fromNodeIndex ||
            (fromNodeIndex == 0 && complaints[schainId].startComplaintBlockTimestamp == 0),
            "Node has already sent complaint"
        );
        require(!dkgProcess[schainId].completed[index], "Node is already alright");
        dkgProcess[schainId].completed[index] = true;
        dkgProcess[schainId].numberOfCompleted++;
        emit AllDataReceived(schainId, fromNodeIndex);
        if (dkgProcess[schainId].numberOfCompleted == numberOfParticipant) {
            _setSuccesfulDKG(schainId);
        }
    }

    function getChannelStartedTime(bytes32 schainId) external view returns (uint) {
        return channels[schainId].startedBlockTimestamp;
    }

    function getChannelStartedBlock(bytes32 schainId) external view returns (uint) {
        return channels[schainId].startedBlock;
    }

    function getNumberOfBroadcasted(bytes32 schainId) external view returns (uint) {
        return dkgProcess[schainId].numberOfBroadcasted;
    }

    function getNumberOfCompleted(bytes32 schainId) external view returns (uint) {
        return dkgProcess[schainId].numberOfCompleted;
    }

    function getTimeOfLastSuccesfulDKG(bytes32 schainId) external view returns (uint) {
        return lastSuccesfulDKG[schainId];
    }

    function getComplaintData(bytes32 schainId) external view returns (uint, uint) {
        return (complaints[schainId].fromNodeToComplaint, complaints[schainId].nodeToComplaint);
    }

    function getComplaintStartedTime(bytes32 schainId) external view returns (uint) {
        return complaints[schainId].startComplaintBlockTimestamp;
    }

    function getAlrightStartedTime(bytes32 schainId) external view returns (uint) {
        return startAlrightTimestamp[schainId];
    }

    function isChannelOpened(bytes32 schainId) external override view returns (bool) {
        return channels[schainId].active;
    }

    function isLastDKGSuccesful(bytes32 schainId) external override view returns (bool) {
        return channels[schainId].startedBlockTimestamp <= lastSuccesfulDKG[schainId];
    }

    function isBroadcastPossible(bytes32 schainId, uint nodeIndex) external view returns (bool) {
        uint index = _nodeIndexInSchain(schainId, nodeIndex);
        return channels[schainId].active &&
            index <  channels[schainId].n &&
            _isNodeByMessageSender(nodeIndex, msg.sender) &&
            !dkgProcess[schainId].broadcasted[index];
    }

    function isComplaintPossible(
        bytes32 schainId,
        uint fromNodeIndex,
        uint toNodeIndex
    )
        external
        view
        returns (bool)
    {
        uint indexFrom = _nodeIndexInSchain(schainId, fromNodeIndex);
        uint indexTo = _nodeIndexInSchain(schainId, toNodeIndex);
        bool complaintSending = (
                complaints[schainId].nodeToComplaint == uint(-1) &&
                dkgProcess[schainId].broadcasted[indexTo] &&
                !dkgProcess[schainId].completed[indexFrom]
            ) ||
            (
                dkgProcess[schainId].broadcasted[indexTo] &&
                complaints[schainId].startComplaintBlockTimestamp.add(COMPLAINT_TIMELIMIT) <= block.timestamp &&
                complaints[schainId].nodeToComplaint == toNodeIndex
            ) ||
            (
                !dkgProcess[schainId].broadcasted[indexTo] &&
                complaints[schainId].nodeToComplaint == uint(-1) &&
                channels[schainId].startedBlockTimestamp.add(COMPLAINT_TIMELIMIT) <= block.timestamp
            ) ||
            (
                complaints[schainId].nodeToComplaint == uint(-1) &&
                isEveryoneBroadcasted(schainId) &&
                dkgProcess[schainId].completed[indexFrom] &&
                !dkgProcess[schainId].completed[indexTo] &&
                startAlrightTimestamp[schainId].add(COMPLAINT_TIMELIMIT) <= block.timestamp
            );
        return channels[schainId].active &&
            indexFrom < channels[schainId].n &&
            indexTo < channels[schainId].n &&
            dkgProcess[schainId].broadcasted[indexFrom] &&
            _isNodeByMessageSender(fromNodeIndex, msg.sender) &&
            complaintSending;
    }

    function isAlrightPossible(bytes32 schainId, uint nodeIndex) external view returns (bool) {
        uint index = _nodeIndexInSchain(schainId, nodeIndex);
        return channels[schainId].active &&
            index < channels[schainId].n &&
            _isNodeByMessageSender(nodeIndex, msg.sender) &&
            channels[schainId].n == dkgProcess[schainId].numberOfBroadcasted &&
            (complaints[schainId].fromNodeToComplaint != nodeIndex ||
            (nodeIndex == 0 && complaints[schainId].startComplaintBlockTimestamp == 0)) &&
            !dkgProcess[schainId].completed[index];
    }

    function isResponsePossible(bytes32 schainId, uint nodeIndex) external view returns (bool) {
        uint index = _nodeIndexInSchain(schainId, nodeIndex);
        return channels[schainId].active &&
            index < channels[schainId].n &&
            _isNodeByMessageSender(nodeIndex, msg.sender) &&
            complaints[schainId].nodeToComplaint == nodeIndex;
    }

    function initialize(address contractsAddress) public override initializer {
        Permissions.initialize(contractsAddress);
    }

    function isNodeBroadcasted(bytes32 schainId, uint nodeIndex) public view returns (bool) {
        uint index = _nodeIndexInSchain(schainId, nodeIndex);
        return index < channels[schainId].n && dkgProcess[schainId].broadcasted[index];
    }

    function isEveryoneBroadcasted(bytes32 schainId) public view returns (bool) {
        return channels[schainId].n == dkgProcess[schainId].numberOfBroadcasted;
    }

    function isAllDataReceived(bytes32 schainId, uint nodeIndex) public view returns (bool) {
        uint index = _nodeIndexInSchain(schainId, nodeIndex);
        return dkgProcess[schainId].completed[index];
    }

    function getT(uint n) public pure returns (uint) {
        return n.mul(2).add(1).div(3);
    }

    function _setSuccesfulDKG(bytes32 schainId) internal {
        lastSuccesfulDKG[schainId] = now;
        channels[schainId].active = false;
        KeyStorage(contractManager.getContract("KeyStorage")).finalizePublicKey(schainId);
        emit SuccessfulDKG(schainId);
    }

    function _verifyDataAndSlash(
        bytes32 schainId,
        uint indexOnSchain,
        uint secretNumber,
        G2Operations.G2Point calldata multipliedShare,
        G2Operations.G2Point[] calldata verificationVector,
        bytes32 share
    )
        internal
    {
        bytes32[2] memory publicKey = Nodes(contractManager.getContract("Nodes")).getNodePublicKey(
            complaints[schainId].fromNodeToComplaint
        );
        uint256 pkX = uint(publicKey[0]);

        (pkX, ) = ECDH(contractManager.getContract("ECDH")).deriveKey(secretNumber, pkX, uint(publicKey[1]));
        bytes32 key = bytes32(pkX);

        // Decrypt secret key contribution
        uint secret = Decryption(contractManager.getContract("Decryption")).decrypt(
            share,
            key
        );

        uint badNode = (_checkCorrectMultipliedShare(multipliedShare, indexOnSchain, secret, verificationVector) ?
            complaints[schainId].fromNodeToComplaint : complaints[schainId].nodeToComplaint);
        _finalizeSlashing(schainId, badNode);
    }

    function _checkCorrectMultipliedShare(
        G2Operations.G2Point memory multipliedShare,
        uint indexOnSchain,
        uint secret,
        G2Operations.G2Point[] calldata verificationVector
    )
        private
        view
        returns (bool)
    {
        if (!multipliedShare.isG2()) {
            return false;
        }
        G2Operations.G2Point memory value = G2Operations.getG2Zero();
        G2Operations.G2Point memory tmp = G2Operations.getG2Zero();
        for (uint i = 0; i < verificationVector.length; i++) {
            tmp = verificationVector[i].mulG2(indexOnSchain.add(1) ** i);
            value = tmp.addG2(value);
        }
        tmp = multipliedShare;
        Fp2Operations.Fp2Point memory g1 = G2Operations.getG1();
        Fp2Operations.Fp2Point memory share = Fp2Operations.Fp2Point({
            a: 0,
            b: 0
        });
        (share.a, share.b) = Precompiled.bn256ScalarMul(g1.a, g1.b, secret);
        if (!(share.a == 0 && share.b == 0)) {
            share.b = Fp2Operations.P.sub((share.b % Fp2Operations.P));
        }

        require(G2Operations.isG1(share), "mulShare not in G1");

        G2Operations.G2Point memory g2 = G2Operations.getG2();
        require(G2Operations.isG2(tmp), "tmp not in g2");

        return value.isEqual(multipliedShare) && Precompiled.bn256Pairing(
            share.a, share.b,
            g2.x.b, g2.x.a, g2.y.b, g2.y.a,
            g1.a, g1.b,
            tmp.x.b, tmp.x.a, tmp.y.b, tmp.y.a);
    }

    function _openChannel(bytes32 schainId) private {
        SchainsInternal schainsInternal = SchainsInternal(
            contractManager.getContract("SchainsInternal")
        );

        uint len = schainsInternal.getNumberOfNodesInGroup(schainId);
        channels[schainId].active = true;
        channels[schainId].n = len;
        delete dkgProcess[schainId].completed;
        delete dkgProcess[schainId].broadcasted;
        dkgProcess[schainId].broadcasted = new bool[](len);
        dkgProcess[schainId].completed = new bool[](len);
        complaints[schainId].fromNodeToComplaint = uint(-1);
        complaints[schainId].nodeToComplaint = uint(-1);
        delete complaints[schainId].startComplaintBlockTimestamp;
        delete dkgProcess[schainId].numberOfBroadcasted;
        delete dkgProcess[schainId].numberOfCompleted;
        channels[schainId].startedBlockTimestamp = now;
        channels[schainId].startedBlock = block.number;
        KeyStorage(contractManager.getContract("KeyStorage")).initPublicKeyInProgress(schainId);

        emit ChannelOpened(schainId);
    }

    function _handleComplaintWhenBroadcasted(bytes32 schainId, uint fromNodeIndex, uint toNodeIndex) private {
        // incorrect data or missing alright
        if (complaints[schainId].nodeToComplaint == uint(-1)) {
            if (
                isEveryoneBroadcasted(schainId) &&
                !isAllDataReceived(schainId, toNodeIndex) &&
                startAlrightTimestamp[schainId].add(COMPLAINT_TIMELIMIT) <= block.timestamp
            ) {
                // missing alright
                _finalizeSlashing(schainId, toNodeIndex);
                return;
            } else if (!isAllDataReceived(schainId, fromNodeIndex)) {
                // incorrect data
                complaints[schainId].nodeToComplaint = toNodeIndex;
                complaints[schainId].fromNodeToComplaint = fromNodeIndex;
                complaints[schainId].startComplaintBlockTimestamp = block.timestamp;
                emit ComplaintSent(schainId, fromNodeIndex, toNodeIndex);
                return;
            }
            emit ComplaintError("Has already sent alright");
            return;
        } else if (complaints[schainId].nodeToComplaint == toNodeIndex) {
            // 30 min after incorrect data complaint
            if (complaints[schainId].startComplaintBlockTimestamp.add(COMPLAINT_TIMELIMIT) <= block.timestamp) {
                _finalizeSlashing(schainId, complaints[schainId].nodeToComplaint);
                return;
            }
            emit ComplaintError("The same complaint rejected");
            return;
        }
        emit ComplaintError("One complaint is already sent");
    }

    function _finalizeSlashing(bytes32 schainId, uint badNode) private {
        NodeRotation nodeRotation = NodeRotation(contractManager.getContract("NodeRotation"));
        SchainsInternal schainsInternal = SchainsInternal(
            contractManager.getContract("SchainsInternal")
        );
        emit BadGuy(badNode);
        emit FailedDKG(schainId);

        if (schainsInternal.isAnyFreeNode(schainId)) {
            uint newNode = nodeRotation.rotateNode(
                badNode,
                schainId,
                false
            );
            emit NewGuy(newNode);
        } else {
            _openChannel(schainId);
            schainsInternal.removeNodeFromSchain(
                badNode,
                schainId
            );
            channels[schainId].active = false;
        }
        Punisher(contractManager.getContract("Punisher")).slash(
            Nodes(contractManager.getContract("Nodes")).getValidatorId(badNode),
            SlashingTable(contractManager.getContract("SlashingTable")).getPenalty("FailedDKG")
        );
    }

    function _nodeIndexInSchain(bytes32 schainId, uint nodeIndex) private view returns (uint) {
        return SchainsInternal(contractManager.getContract("SchainsInternal"))
            .getNodeIndexInGroup(schainId, nodeIndex);
    }

    function _isNodeByMessageSender(uint nodeIndex, address from) private view returns (bool) {
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        return nodes.isNodeExist(from, nodeIndex);
    }

    function _hashData(
        KeyShare[] memory secretKeyContribution,
        G2Operations.G2Point[] memory verificationVector
    )
        private
        pure
        returns (bytes32)
    {
        bytes memory data;
        for (uint i = 0; i < secretKeyContribution.length; i++) {
            data = abi.encodePacked(data, secretKeyContribution[i].publicKey, secretKeyContribution[i].share);
        }
        for (uint i = 0; i < verificationVector.length; i++) {
            data = abi.encodePacked(
                data,
                verificationVector[i].x.a,
                verificationVector[i].x.b,
                verificationVector[i].y.a,
                verificationVector[i].y.b
            );
        }
        return keccak256(data);
    }
}