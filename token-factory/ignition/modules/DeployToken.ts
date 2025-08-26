import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const DeployTokenModule = buildModule("DeployTokenModule", (m) => {
  const tokenDeployer = m.contract("TokenDeployer");

  return { tokenDeployer };
});

export default DeployTokenModule;
