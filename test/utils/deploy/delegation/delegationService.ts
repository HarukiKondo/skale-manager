import { ContractManagerInstance, DelegationServiceContract } from "../../../../types/truffle-contracts";
import { deploySkaleToken } from "../skaleToken";
import { deployDelegationController } from "./delegationController";
import { deployDistributor } from "./distributor";
import { deployTokenState } from "./tokenState";
import { deployValidatorService } from "./validatorService";

const DelegationService: DelegationServiceContract = artifacts.require("./DelegationService");
const name = "DelegationService";

async function deploy(contractManager: ContractManagerInstance) {
    const instance = await DelegationService.new();
    await instance.initialize(contractManager.address);
    await contractManager.setContractsAddress(name, instance.address);
    return instance;
}

async function deployDependencies(contractManager: ContractManagerInstance) {
    await deployTokenState(contractManager);
    await deployDelegationController(contractManager);
    await deployValidatorService(contractManager);
    await deployDistributor(contractManager);
    await deploySkaleToken(contractManager);
}

export async function deployDelegationService(contractManager: ContractManagerInstance) {
    try {
        return DelegationService.at(await contractManager.getContract(name));
    } catch (e) {
        const instance = await deploy(contractManager);
        await deployDependencies(contractManager);
        return instance;
    }
}
