import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const SimpleDexV3Module = buildModule("SimpleDexV3Module", (m) => {
  const simpleDexV3 = m.contract("SimpleDexV3", []);
  return { simpleDexV3 };
});

export default SimpleDexV3Module;
