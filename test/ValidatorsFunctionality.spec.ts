import { BigNumber } from "bignumber.js";
import {
        ConstantsHolderContract,
        ConstantsHolderInstance,
        ContractManagerContract,
        ContractManagerInstance,
        NodesDataContract,
        NodesDataInstance,
        NodesFunctionalityContract,
        NodesFunctionalityInstance,
        ValidatorsDataContract,
        ValidatorsDataInstance,
        ValidatorsFunctionalityContract,
        ValidatorsFunctionalityInstance,
      } from "../types/truffle-contracts";
import { gasMultiplier } from "./utils/command_line";
import { skipTime } from "./utils/time";

import chai = require("chai");
import * as chaiAsPromised from "chai-as-promised";
chai.should();
chai.use((chaiAsPromised));

const ContractManager: ContractManagerContract = artifacts.require("./ContractManager");
const ValidatorsFunctionality: ValidatorsFunctionalityContract = artifacts.require("./ValidatorsFunctionality");
const ConstantsHolder: ConstantsHolderContract = artifacts.require("./ConstantsHolder");
const ValidatorsData: ValidatorsDataContract = artifacts.require("./ValidatorsData");
const NodesData: NodesDataContract = artifacts.require("./NodesData");
const NodesFunctionality: NodesFunctionalityContract = artifacts.require("./NodesFunctionality");

contract("ValidatorsFunctionality", ([owner, validator]) => {
  let contractManager: ContractManagerInstance;
  let validatorsFunctionality: ValidatorsFunctionalityInstance;
  let constantsHolder: ConstantsHolderInstance;
  let validatorsData: ValidatorsDataInstance;
  let nodesData: NodesDataInstance;
  let nodesFunctionality: NodesFunctionalityInstance;

  beforeEach(async () => {
    contractManager = await ContractManager.new({from: owner});

    validatorsFunctionality = await ValidatorsFunctionality.new(
      "SkaleManager", "ValidatorsData",
      contractManager.address, {from: owner, gas: 8000000 * gasMultiplier});
    await contractManager.setContractsAddress("ValidatorsFunctionality", validatorsFunctionality.address);

    validatorsData = await ValidatorsData.new(
      "ValidatorsFunctionality",
      contractManager.address, {from: owner, gas: 8000000 * gasMultiplier});
    await contractManager.setContractsAddress("ValidatorsData", validatorsData.address);

    constantsHolder = await ConstantsHolder.new(
      contractManager.address, {from: owner, gas: 8000000 * gasMultiplier});
    await contractManager.setContractsAddress("Constants", constantsHolder.address);

    nodesData = await NodesData.new(
        5260000,
        contractManager.address,
        {from: owner, gas: 8000000 * gasMultiplier});
    await contractManager.setContractsAddress("NodesData", nodesData.address);

    nodesFunctionality = await NodesFunctionality.new(
      contractManager.address,
      {from: owner, gas: 8000000 * gasMultiplier});
    await contractManager.setContractsAddress("NodesFunctionality", nodesFunctionality.address);

    // create a node for validators functions tests
    await nodesData.addNode(validator, "elvis1", "0x7f000001", "0x7f000002", 8545, "0x1122334455");
    await nodesData.addNode(validator, "elvis2", "0x7f000003", "0x7f000004", 8545, "0x1122334456");
    await nodesData.addNode(validator, "elvis3", "0x7f000005", "0x7f000006", 8545, "0x1122334457");
    await nodesData.addNode(validator, "elvis4", "0x7f000007", "0x7f000008", 8545, "0x1122334458");
    await nodesData.addNode(validator, "elvis5", "0x7f000009", "0x7f000010", 8545, "0x1122334459");
  });
  // nodeIndex = 0 because we add one node and her index in array is 0
  const nodeIndex = 0;

  it("should add Validator", async () => {
    const { logs } = await validatorsFunctionality.addValidator(nodeIndex, {from: owner});
    // check events after `.addValidator` invoke
    assert.equal(logs[0].event, "GroupAdded");
    assert.equal(logs[1].event, "GroupGenerated");
    assert.equal(logs[2].event, "ValidatorsArray");
    assert.equal(logs[3].event, "ValidatorCreated");
  });

  it("should upgrade Validator", async () => {
    // add validator
    await validatorsFunctionality.addValidator(nodeIndex, {from: owner});
    // upgrade Validator
    const { logs } = await validatorsFunctionality.upgradeValidator(nodeIndex, {from: owner});
    // check events after `.upgradeValidator` invoke
    assert.equal(logs[0].event, "GroupUpgraded");
    assert.equal(logs[1].event, "GroupGenerated");
    assert.equal(logs[2].event, "ValidatorsArray");
    assert.equal(logs[3].event, "ValidatorUpgraded");
  });

  it("should send Verdict", async () => {
    // preparation
    // ip = 127.0.0.1
    const ipToHex = "7f000001";
    const indexNode0 = 0;
    const indexNode0inSha3 = web3.utils.soliditySha3(indexNode0);
    const indexNode1 = 1;
    const indexNode1ToHex = ("0000000000000000000000000000000000" +
        indexNode1).slice(-28);
    const timeInSec = 1;
    const timeToHex = ("0000000000000000000000000000000000" +
        timeInSec).slice(-28);
    const data32bytes = "0x" + indexNode1ToHex + timeToHex + ipToHex;
    //
    await validatorsFunctionality.addValidator(indexNode0, {from: owner});
    //
    await validatorsData.addValidatedNode(
      indexNode0inSha3, data32bytes, {from: owner},
      );
    // execution
    const { logs } = await validatorsFunctionality
          .sendVerdict(0, indexNode1, 1, 0, {from: owner});
    // assertation
    assert.equal(logs[0].event, "VerdictWasSent");
  });

  it("should rejected with `Validated Node...` error when invoke sendVerdict", async () => {
    const error = "Validated Node does not exist in ValidatorsArray";
    await validatorsFunctionality
          .sendVerdict(0, 1, 0, 0, {from: owner})
          .should.be.eventually.rejectedWith(error);
  });

  it("should rejected with `The time has...` error when invoke sendVerdict", async () => {
    const error = "The time has not come to send verdict";
    // preparation
    // ip = 127.0.0.1
    const ipToHex = "7f000001";
    const indexNode0 = 0;
    const indexNode0inSha3 = web3.utils.soliditySha3(indexNode0);
    const indexNode1 = 1;
    const indexNode1ToHex = ("0000000000000000000000000000000000" +
        indexNode1).slice(-28);
    const time = parseInt((new Date().getTime() / 1000).toFixed(0) + 3600, 10);
    const timeInHex = time.toString(16);
    const add0ToHex = ("00000000000000000000000000000" +
    timeInHex).slice(-28);
    // for data32bytes should revert to hex indexNode1 + oneSec + 127.0.0.1
    const data32bytes = "0x" + indexNode1ToHex + add0ToHex + ipToHex;
    //
    // await validatorsFunctionality.addValidator(indexNode0, {from: owner});
    //
    await validatorsData.addValidatedNode(
      indexNode0inSha3, data32bytes, {from: owner},
      );
    await validatorsFunctionality
          .sendVerdict(0, 1, 0, 0, {from: owner})
          .should.be.eventually.rejectedWith(error);
  });

  it("should calculate Metrics", async () => {
    // preparation
    const indexNode1 = 1;
    const validatorIndex1 = web3.utils.soliditySha3(indexNode1);
    await validatorsData.addVerdict(
      validatorIndex1, 10, 0, {from: owner},
      );
    const res = new BigNumber(await validatorsData.getLengthOfMetrics(validatorIndex1, {from: owner}));
    expect(parseInt(res.toString(), 10)).to.equal(1);
    // execution
    await validatorsFunctionality
          .calculateMetrics(indexNode1, {from: owner});
    const res2 = new BigNumber(await validatorsData.getLengthOfMetrics(validatorIndex1, {from: owner}));
    // expectation
    expect(parseInt(res2.toString(), 10)).to.equal(0);
  });

  it("should add verdict when sendVerdict invoke", async () => {
    // preparation
    // ip = 127.0.0.1
    const ipToHex = "7f000001";
    const indexNode0 = 0;
    const indexNode0inSha3 = web3.utils.soliditySha3(indexNode0);
    const indexNode1 = 1;
    const validatorIndex1 = web3.utils.soliditySha3(indexNode1);
    const indexNode1ToHex = ("0000000000000000000000000000000000" +
        indexNode1).slice(-28);
    // const time = parseInt((new Date().getTime() / 1000).toFixed(0), 10);
// tslint:disable-next-line: no-bitwise
    const time = (new Date().getTime() / 1000) >> 0;
    const timeInHex = time.toString(16);
    const add0ToHex = ("00000000000000000000000000000" +
    timeInHex).slice(-28);
    const data32bytes = "0x" + indexNode1ToHex + add0ToHex + ipToHex;
    //
    await validatorsData.addValidatedNode(
      indexNode0inSha3, data32bytes, {from: owner},
      );
    // execution
    // skipTime(web3, time - 200);
    await validatorsFunctionality
          .sendVerdict(0, 1, 0, 0, {from: owner});
    const res = new BigNumber(await validatorsData.getLengthOfMetrics(validatorIndex1, {from: owner}));
    // expectation
    expect(parseInt(res.toString(), 10)).to.equal(1);
  });

});
