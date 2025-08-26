import "@nomicfoundation/hardhat-toolbox";
import type { HardhatUserConfig } from "hardhat/config";

const config: HardhatUserConfig = {
  solidity: "0.8.28",
  networks: {
    ility: {
      url: "https://ily.blockgateway.net",
      chainId: 69923,
      accounts: [
        "fa5efb133cb1ff4f4b42c6a5878d75e3c86cb88c7a3a267ee58667e1f31741cd",
      ],
    },
  },
};

export default config;
