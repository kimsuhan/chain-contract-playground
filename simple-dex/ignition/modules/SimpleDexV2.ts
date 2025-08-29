import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const SimpleDexV2Module = buildModule("SimpleDexV2Module", (m) => {
  const simpleDexV2 = m.contract("SimpleDexV2", []);
  return { simpleDexV2 };
});

export default SimpleDexV2Module;
