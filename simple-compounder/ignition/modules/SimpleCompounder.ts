import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const SimpleCompounderModule = buildModule("SimpleCompounderModule", (m) => {
  const simplePriceOracle = m.contract("SimplePriceOracle");
  const jumpRateModel = m.contract("JumpRateModel", [
    BigInt(0.05 * 1e18), // 5% 기본 이자율
    BigInt(0.12 * 1e18), // 12% 이자율 증가율
    BigInt(4 * 1e18), // 400% 이자율 증가율
    BigInt(0.8 * 1e18), // 0.8% kink
  ]);

  const comptroller = m.contract("Comptroller");

  // 2. 기본 설정만
  m.call(comptroller, "_setPriceOracle", [simplePriceOracle]);
  m.call(comptroller, "_setLiquidationIncentive", ["1080000000000000000"]); // 8% 인센티브

  return { simplePriceOracle, jumpRateModel, comptroller };
});

export default SimpleCompounderModule;
