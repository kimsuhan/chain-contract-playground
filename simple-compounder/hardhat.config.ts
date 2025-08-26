import "@nomicfoundation/hardhat-toolbox";
import type { HardhatUserConfig } from "hardhat/config";

const config: HardhatUserConfig = {
  solidity: "0.8.28",
  networks: {
    ility: {
      url: "https://ily.blockgateway.net",
      chainId: 69923,
      accounts: [],
    },
  },
};

export default config;
